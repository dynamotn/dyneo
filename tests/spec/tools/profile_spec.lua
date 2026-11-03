local h = require('helpers')

describe('tools.profile', function()
  local profile, dir, cleanup, path, notes, restore_notify, loaded

  before_each(function()
    h.unload('tools.profile')
    profile = require('tools.profile')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    loaded = nil
    package.loaded.perfanno = {
      load_traces = function(traces) loaded = traces end,
    }
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    package.loaded.perfanno = nil
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- A fake `name` on the private `$PATH` printing `lines`
  local function fake(name, lines)
    local script = { '#!/bin/sh', "cat <<'EOF'" }
    vim.list_extend(script, lines)
    table.insert(script, 'EOF')
    h.write(dir .. '/bin/' .. name, script)
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  it('defines :DyProfile', function()
    dofile(h.root .. '/plugin/profile.lua')
    assert.equals(2, vim.fn.exists(':DyProfile'))
  end)

  it('reads py-spy and flamegraph stacks, root first', function()
    local traces = profile.parse_collapsed({
      'process 1:"python3 x.py";<module> (/p/x.py:12);work (/p/x.py:4) 7',
      'main /p/a.c:3;f /p/a.c:9 5',
      'not a stack',
    })
    assert.same({
      time = {
        {
          count = 7,
          frames = {
            { symbol = 'process 1:"python3 x.py"' },
            { symbol = '<module>', file = '/p/x.py', linenr = 12 },
            { symbol = 'work', file = '/p/x.py', linenr = 4 },
          },
        },
        {
          count = 5,
          frames = {
            { symbol = 'main', file = '/p/a.c', linenr = 3 },
            { symbol = 'f', file = '/p/a.c', linenr = 9 },
          },
        },
      },
    }, traces)
  end)

  it('reads pprof traces in microseconds, root first', function()
    local traces = profile.parse_pprof({
      'File: gop.test',
      'Type: cpu',
      '-----------+-------------------------------------------------------',
      '      90ms   gop.work /p/hot_test.go:7 (inline)',
      '             gop.TestHot /p/hot_test.go:15',
      '-----------+-------------------------------------------------------',
      '     1.5s   gop.idle /p/idle.go:3',
      '-----------+-------------------------------------------------------',
    })
    assert.same({
      time = {
        {
          count = 90000,
          frames = {
            { symbol = 'gop.TestHot', file = '/p/hot_test.go', linenr = 15 },
            { symbol = 'gop.work', file = '/p/hot_test.go', linenr = 7 },
          },
        },
        {
          count = 1500000,
          frames = { { symbol = 'gop.idle', file = '/p/idle.go', linenr = 3 } },
        },
      },
    }, traces)
  end)

  it('reads a .cpuprofile, its ticks on their own lines', function()
    local traces = profile.parse_cpuprofile({
      nodes = {
        { id = 1, callFrame = { functionName = '(root)', url = '' } },
        {
          id = 2,
          callFrame = {
            functionName = 'main',
            url = 'file:///p/a.js',
            lineNumber = 8,
          },
          parent = nil,
          children = { 3 },
        },
        {
          id = 3,
          callFrame = {
            functionName = 'work',
            url = 'file:///p/a.js',
            lineNumber = 0,
          },
          hitCount = 10,
          positionTicks = { { line = 4, ticks = 6 } },
        },
      },
    })
    -- `(root)` holds no child list here, so `main` is a root of its own
    local main = { symbol = 'main', file = '/p/a.js', linenr = 9 }
    assert.same({
      time = {
        {
          count = 6,
          frames = { main, { symbol = 'work', file = '/p/a.js', linenr = 4 } },
        },
        {
          count = 4,
          frames = { main, { symbol = 'work', file = '/p/a.js', linenr = 1 } },
        },
      },
    }, traces)
  end)

  it('reads perf report stacks by event', function()
    local traces = profile.parse_perf_report({
      "# Samples: 1K of event 'cycles'",
      '#',
      '12 main /p/a.c:3;f /p/a.c:9',
      '0 main /p/a.c:3',
    })
    assert.same({
      cycles = {
        {
          count = 12,
          frames = {
            { symbol = 'main', file = '/p/a.c', linenr = 3 },
            { symbol = 'f', file = '/p/a.c', linenr = 9 },
          },
        },
      },
    }, traces)
  end)

  it('builds the profiler of each filetype', function()
    local cmd, cwd = profile.command('python', '/p/x.py', {}, '/o/out')
    assert.same({
      'py-spy',
      'record',
      '--format',
      'raw',
      '--full-filenames',
      '-o',
      '/o/out',
      '--',
      'python3',
      '/p/x.py',
    }, cmd)
    assert.equals('/p', cwd)
    cmd = profile.command('python', '/p/x.py', { 'uv', 'run', 'app' }, '/o')
    assert.same({ 'uv', 'run', 'app' }, vim.list_slice(cmd, 9))
    cmd, cwd = profile.command('go', '/p/pkg/a.go', { '-bench', '.' }, '/o')
    assert.same({ 'go', 'test', '-cpuprofile', '/o', '-bench', '.' }, cmd)
    assert.equals('/p/pkg', cwd)
    cmd = profile.command('typescript', '/p/a.ts', {}, '/o')
    assert.same(
      { 'node', '--cpu-prof', '--cpu-prof-dir', '/o', '/p/a.ts' },
      cmd
    )
  end)

  it('asks for the program of a native one, and only on Linux', function()
    local restore = h.stub(
      vim.uv,
      'os_uname',
      function() return { sysname = 'Linux' } end
    )
    local cmd, err = profile.command('rust', '/p/src/main.rs', {}, '/o')
    assert.is_nil(cmd)
    assert.matches('the program to profile', err)
    cmd = profile.command('rust', '/p/src/main.rs', { './app' }, '/o')
    assert.same(
      { 'perf', 'record', '--call-graph', 'dwarf', '-o', '/o', '--', './app' },
      cmd
    )
    restore()
    restore = h.stub(
      vim.uv,
      'os_uname',
      function() return { sysname = 'Darwin' } end
    )
    cmd, err = profile.command('c', '/p/a.c', { './app' }, '/o')
    restore()
    assert.is_nil(cmd)
    assert.matches('Linux', err)
    cmd, err = profile.command('markdown', '/p/a.md', {}, '/o')
    assert.is_nil(cmd)
    assert.matches('markdown', err)
  end)

  it('loads a pprof profile through go tool pprof', function()
    fake('go', {
      '-----------+-------------------------------------------------------',
      '      20ms   main.f /p/main.go:4',
    })
    h.write(dir .. '/cpu.pprof', { 'binary' })
    profile.load(dir .. '/cpu.pprof')
    assert.is_true(vim.wait(2000, function() return loaded ~= nil end))
    assert.equals(20000, loaded.time[1].count)
  end)

  it('says so when a profile holds no samples', function()
    h.write(dir .. '/empty.txt', { '' })
    profile.load(dir .. '/empty.txt')
    assert.is_nil(loaded)
    assert.matches('no samples', notes[#notes])
  end)
end)
