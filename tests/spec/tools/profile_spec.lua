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

  it('reads a Go allocation profile in bytes', function()
    local traces = profile.parse_pprof({
      'File: gomem.test',
      'Type: alloc_space',
      '-----------+-------------------------------------------------------',
      '     bytes:  1MB',
      '      20MB   gomem.big /p/hot_test.go:8 (inline)',
      '             gomem.TestHot /p/hot_test.go:19',
      '-----------+-------------------------------------------------------',
      '     bytes:  8kB',
      '         0   runtime/pprof.writeHeapInternal /r/pprof.go:650',
      '-----------+-------------------------------------------------------',
      '     bytes:  896B',
      '      896B   gomem.big /p/hot_test.go:8 (inline)',
    })
    assert.same({ profile.MEMORY }, vim.tbl_keys(traces))
    local list = traces[profile.MEMORY]
    -- Nothing allocated is no stack; a unit is a power of 1024
    assert.equals(2, #list)
    assert.equals(20 * 1024 * 1024, list[1].count)
    assert.same({
      { symbol = 'gomem.TestHot', file = '/p/hot_test.go', linenr = 19 },
      { symbol = 'gomem.big', file = '/p/hot_test.go', linenr = 8 },
    }, list[1].frames)
    assert.equals(896, list[2].count)
  end)

  it('reads a memray report, its files from the project', function()
    local traces = profile.parse_memray({
      'allocator,num_allocations,size,tid,thread_name,stack_trace',
      'MALLOC,50,52428850,1,0x1,big;hot.py;8|main;hot.py;13|run_path;<frozen runpy>;291',
      'MALLOC,1,710,1,"main, worker",f;/abs/x.py;3',
      'FREE,1,0,1,0x1,f;/abs/x.py;4',
      '',
    }, '/p')
    local list = traces[profile.MEMORY]
    assert.equals(2, #list)
    assert.equals(52428850, list[1].count)
    assert.same({
      { symbol = 'run_path' },
      { symbol = 'main', file = '/p/hot.py', linenr = 13 },
      { symbol = 'big', file = '/p/hot.py', linenr = 8 },
    }, list[1].frames)
    -- A quoted field keeps its comma
    assert.same(
      { { symbol = 'f', file = '/abs/x.py', linenr = 3 } },
      list[2].frames
    )
  end)

  it('loads a memray capture through memray transform', function()
    h.write(dir .. '/bin/memray', {
      '#!/bin/sh',
      -- memray transform csv -o OUT IN
      'printf "allocator,num_allocations,size,tid,thread_name,stack_trace\\n'
        .. 'MALLOC,1,64,1,0x1,f;a.py;2\\n" > "$4"',
    })
    vim.fn.setfperm(dir .. '/bin/memray', 'rwxr-xr-x')
    h.write(dir .. '/out.bin', { 'binary' })
    profile.load(dir .. '/out.bin', '/p')
    assert.is_true(vim.wait(2000, function() return loaded ~= nil end))
    assert.equals('/p/a.py', loaded[profile.MEMORY][1].frames[1].file)
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

  it('builds the memory profiler of each filetype', function()
    local cmd, cwd = profile.command('python', '/p/x.py', {}, '/o.bin', true)
    assert.same({ 'memray', 'run', '-o', '/o.bin', '/p/x.py' }, cmd)
    assert.equals('/p', cwd)
    cmd = profile.command('python', '/p/x.py', { '-m', 'app' }, '/o', true)
    assert.same({ 'memray', 'run', '-o', '/o', '-m', 'app' }, cmd)
    cmd = profile.command('go', '/p/pkg/a.go', {}, '/o', true)
    assert.same({ 'go', 'test', '-memprofile', '/o', '-memprofilerate=1' }, cmd)
    local err
    cmd, err = profile.command('typescript', '/p/a.ts', {}, '/o', true)
    assert.is_nil(cmd)
    assert.matches('No memory profiler for typescript', err)
    assert.matches('go, java', err)
    local restore = h.stub(
      vim.uv,
      'os_uname',
      function() return { sysname = 'Windows_NT' } end
    )
    cmd, err = profile.command('python', '/p/x.py', {}, '/o', true)
    restore()
    assert.is_nil(cmd)
    assert.matches('memray only runs on Linux and macOS', err)
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
      function() return { sysname = 'FreeBSD' } end
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
  describe('on the JVM', function()
    local lib, installed, restores

    before_each(function()
      lib, installed = dir .. '/libasyncProfiler', nil
      restores = {
        h.stub(
          profile,
          'async_profiler',
          function() return vim.uv.fs_stat(lib) and lib or nil end
        ),
        h.stub(vim.env, 'JAVA_TOOL_OPTIONS', nil),
        h.stub(package.loaded, 'util.lazy_install', {
          install_once = function(name) installed = name end,
        }),
      }
    end)
    after_each(function()
      for i = #restores, 1, -1 do
        restores[i]()
      end
    end)

    it('loads async-profiler into the program, from its project', function()
      h.write(lib, {})
      h.write(dir .. '/app/pom.xml', {})
      local file = dir .. '/app/src/main/java/a/A.java'
      local cmd, cwd, env =
        profile.command('java', file, { './mvnw', 'exec:java' }, '/o')
      assert.same({ './mvnw', 'exec:java' }, cmd)
      assert.equals(dir .. '/app', cwd)
      assert.equals(
        '-agentpath:'
          .. lib
          .. '=start,event=cpu,interval=10ms,collapsed,lines,file=/o/%p.collapsed',
        env.JAVA_TOOL_OPTIONS
      )
      -- Options already set stay, the agent after them
      vim.env.JAVA_TOOL_OPTIONS = '-Xmx1g'
      _, _, env = profile.command('java', file, { 'java', 'A' }, '/o')
      assert.matches('^%-Xmx1g %-agentpath:', env.JAVA_TOOL_OPTIONS)
      local _, err = profile.command('kotlin', file, {}, '/o')
      assert.matches('the program to profile', err)
    end)

    it('records allocations in bytes with the alloc event', function()
      h.write(lib, {})
      local _, _, env =
        profile.command('java', dir .. '/A.java', { 'java', 'A' }, '/o', true)
      assert.equals(
        '-agentpath:'
          .. lib
          .. '=start,event=alloc,total,collapsed,lines,file=/o/%p.alloc.collapsed',
        env.JAVA_TOOL_OPTIONS
      )
    end)

    it('reads the allocations of a JVM as bytes', function()
      h.write(dir .. '/app/src/A.java', {})
      h.write(
        dir .. '/out/1.alloc.collapsed',
        { 'A.main:1;A.fill:7;byte[] 4096' }
      )
      profile.load(dir .. '/out', dir .. '/app')
      local list = loaded[profile.MEMORY]
      assert.equals(4096, list[1].count)
      assert.same(
        { symbol = 'A.fill', file = dir .. '/app/src/A.java', linenr = 7 },
        list[1].frames[2]
      )
      assert.is_nil(loaded.time)
    end)

    it('has Mason install async-profiler when it is missing', function()
      local cmd, err =
        profile.command('java', '/p/A.java', { 'java', 'A' }, '/o')
      assert.is_nil(cmd)
      assert.matches('async%-profiler', err)
      assert.equals('async-profiler', installed)
    end)

    it('finds the source of each JVM frame in the project', function()
      local root = dir .. '/app'
      h.write(root .. '/src/main/java/com/acme/Bar.java', {})
      h.write(root .. '/src/main/kotlin/com/acme/Baz.kt', {})
      h.write(root .. '/build/generated/com/acme/Bar.java', {})
      local traces = profile.parse_jvm({
        'java/lang/Thread.run:829;com/acme/Bar.work:42;com/acme/Bar$Inner.go:7 9',
        'com/acme/Baz.spin:3 2',
        'not a stack',
      }, root)
      local bar = root .. '/src/main/java/com/acme/Bar.java'
      assert.same({
        { symbol = 'java/lang/Thread.run:829' },
        { symbol = 'Bar.work', file = bar, linenr = 42 },
        { symbol = 'Bar$Inner.go', file = bar, linenr = 7 },
      }, traces.time[1].frames)
      assert.equals(9, traces.time[1].count)
      assert.equals(
        root .. '/src/main/kotlin/com/acme/Baz.kt',
        traces.time[2].frames[1].file
      )
    end)

    it('reads a directory of JVM profiles, one per process', function()
      h.write(dir .. '/app/src/A.java', {})
      h.write(dir .. '/out/1.collapsed', { 'A.main:1 3' })
      h.write(dir .. '/out/2.collapsed', { 'A.main:1 4' })
      profile.load(dir .. '/out', dir .. '/app')
      assert.equals(2, #loaded.time)
      assert.equals(dir .. '/app/src/A.java', loaded.time[1].frames[1].file)
    end)
  end)

  it('draws the loaded profile as a flame graph', function()
    local opened
    local restore_open = h.stub(vim.ui, 'open', function(p) opened = p end)
    profile.flame()
    assert.matches('No profile', notes[#notes])
    h.write(dir .. '/stacks.txt', { 'main /p/a.c:3;f /p/a.c:9 5' })
    profile.load(dir .. '/stacks.txt')
    h.write(dir .. '/bin/inferno-flamegraph', {
      '#!/bin/sh',
      'cat > "' .. dir .. '/collapsed"',
      'echo "<svg/>"',
    })
    vim.fn.setfperm(dir .. '/bin/inferno-flamegraph', 'rwxr-xr-x')
    profile.flame()
    assert.is_true(vim.wait(3000, function() return opened ~= nil end))
    restore_open()
    assert.matches('%.svg$', opened)
    assert.same({ '<svg/>' }, vim.fn.readfile(opened))
    assert.same(
      { 'main /p/a.c:3;f /p/a.c:9 5' },
      vim.fn.readfile(dir .. '/collapsed')
    )
  end)
  it('draws a memory profile counting bytes', function()
    local opened
    local restore_open = h.stub(vim.ui, 'open', function(p) opened = p end)
    h.write(dir .. '/m.csv', {
      'allocator,num_allocations,size,tid,thread_name,stack_trace',
      'MALLOC,1,64,1,0x1,f;/p/a.py;2',
    })
    profile.load(dir .. '/m.csv')
    h.write(dir .. '/bin/inferno-flamegraph', {
      '#!/bin/sh',
      'echo "$@" > "' .. dir .. '/args"',
      'echo "<svg/>"',
    })
    vim.fn.setfperm(dir .. '/bin/inferno-flamegraph', 'rwxr-xr-x')
    profile.flame()
    assert.is_true(vim.wait(3000, function() return opened ~= nil end))
    restore_open()
    assert.matches('%-%-countname bytes', vim.fn.readfile(dir .. '/args')[1])
  end)

  describe('with samply', function()
    -- The shape samply 0.13 saves: a processed profile with addresses only,
    -- and its `.syms.json` sidecar that names them, inline frames and all
    local saved = {
      meta = { preprocessedProfileVersion = 49, symbolicated = false },
      libs = { { name = 'hot', debugName = 'hot', path = './hot' } },
      threads = {
        {
          name = 'hot',
          samples = { length = 3, stack = { 1, 1, 0 }, weight = { 1, 5, 2 } },
          stackTable = { length = 2, frame = { 0, 1 }, prefix = { vim.NIL, 0 } },
          frameTable = { length = 2, address = { 1120, 1160 }, func = { 0, 1 } },
          funcTable = { length = 2, name = { 0, 1 }, resource = { 0, 0 } },
          resourceTable = { length = 1, lib = { 0 } },
          stringArray = { '0x460', '0x488' },
        },
      },
    }
    local syms = {
      string_table = { 'UNKNOWN', 'main', 'work', '/src/hot.c' },
      data = {
        {
          debug_name = 'hot',
          symbol_table = {
            {
              rva = 1120,
              size = 136,
              symbol = 1,
              frames = {
                { ['function'] = 2, file = 3, line = 6 },
                { ['function'] = 1, file = 3, line = 13 },
              },
            },
          },
          known_addresses = { { 1160, 0 } },
        },
      },
    }

    it('names each frame through the sidecar, inline ones too', function()
      local traces = profile.parse_samply(saved, syms).time
      assert.equals(2, #traces)
      -- Stack 1: the frame at 1120 above the one at 1160, which inlines
      -- `work` into `main`
      local hot = traces[1]
      assert.equals(6, hot.count)
      assert.same({
        -- No line for an address the sidecar does not list, but its symbol
        { symbol = 'main' },
        { symbol = 'main', file = '/src/hot.c', linenr = 13 },
        { symbol = 'work', file = '/src/hot.c', linenr = 6 },
      }, hot.frames)
      assert.equals(2, traces[2].count)
    end)

    it('records with samply on macOS, perf on Linux', function()
      local restore = h.stub(
        vim.uv,
        'os_uname',
        function() return { sysname = 'Darwin' } end
      )
      local cmd =
        profile.command('rust', '/p/src/main.rs', { './app' }, '/o.json.gz')
      restore()
      assert.same({
        'samply',
        'record',
        '--save-only',
        '--unstable-presymbolicate',
        '-o',
        '/o.json.gz',
        '--',
        './app',
      }, cmd)
    end)

    it('reads a saved profile and its sidecar', function()
      local file = dir .. '/prof.json'
      h.write(file, { vim.json.encode(saved) })
      h.write(file .. '.syms.json', { vim.json.encode(syms) })
      vim.fn.system({ 'gzip', file })
      profile.load(file .. '.gz')
      assert.is_true(vim.wait(3000, function() return loaded ~= nil end))
      assert.equals('work', loaded.time[1].frames[3].symbol)
    end)
  end)
end)
