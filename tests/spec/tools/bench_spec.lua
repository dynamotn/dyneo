local h = require('helpers')

describe('tools.bench', function()
  local bench, dir, root, cleanup, path, notes, restores, installed
  local trusted, asked, jobs, exit_code, on_job

  before_each(function()
    h.unload('tools.bench')
    bench = require('tools.bench')
    dir, cleanup = h.tmpdir()
    root = vim.uv.fs_realpath(dir) .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root, 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec and git, whatever else the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, installed, jobs, asked = {}, {}, {}, 0
    trusted, exit_code, on_job = true, 0, nil
    local stdpath = vim.fn.stdpath
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(package.loaded, 'util.lazy_install', {
        install_once = function(name) table.insert(installed, name) end,
      }),
      h.stub(package.loaded, 'util.trust', {
        ask = function()
          asked = asked + 1
          return trusted
        end,
      }),
      h.stub(vim.fn, 'jobstart', function(cmd, opts)
        table.insert(jobs, { cmd = cmd, opts = opts })
        if on_job then on_job(cmd) end
        opts.on_exit(1, exit_code)
        return 1
      end),
      h.stub(
        vim.fn,
        'stdpath',
        function(what)
          return what == 'state' and dir .. '/state' or stdpath(what)
        end
      ),
    }
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! stopinsert')
    vim.cmd('silent! tabonly')
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function fake(name)
    h.write(dir .. '/bin/' .. name, { '#!/bin/sh', 'exit 0' })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function noted(pattern, level)
    return vim.wait(2000, function()
      for _, note in ipairs(notes) do
        if
          note.msg:match(pattern) and (level == nil or note.level == level)
        then
          return true
        end
      end
      return false
    end)
  end

  local GO_OUT = {
    'goos: darwin',
    'pkg: example.com/gob',
    'BenchmarkJoin-14    \t  476702\t        48.00 ns/op\t     112 B/op',
    'BenchmarkJoin-14    \t  528343\t        52.00 ns/op\t     112 B/op',
    'BenchmarkSub/small-14 \t  900562\t        26.00 ns/op',
    'PASS',
    'ok  \texample.com/gob\t0.732s',
  }

  it('reads go test output, the mean of each benchmark', function()
    local benches = bench.parse_go(table.concat(GO_OUT, '\n'))
    assert.same(2, #benches)
    assert.same('gob.Join-14', benches[1].name)
    assert.is_true(math.abs(benches[1].value - 50e-9) < 1e-15)
    assert.is_true(math.abs(benches[1].stddev - math.sqrt(8) * 1e-9) < 1e-15)
    assert.same('gob.Sub/small-14', benches[2].name)
    assert.is_nil(benches[2].stddev)
  end)

  it('reads the p-values of benchstat, its time table only', function()
    local stats = bench.parse_benchstat(table.concat({
      'goos: darwin',
      'pkg: example.com/gob',
      ',old.txt,,new.txt,,,',
      ',sec/op,CI,sec/op,CI,vs base,P',
      'Join-14,4.8e-08,5%,4.8e-08,7%,~,p=0.818 n=6',
      'Sub/small-14,2.6e-08,6%,8.2e-08,11%,+207.67%,p=0.002 n=6',
      'geomean,3.5e-08,,6.2e-08,,+75.34%,',
      '',
      ',old.txt,,new.txt,,,',
      ',B/op,CI,B/op,CI,vs base,P',
      'Join-14,112,0%,112,0%,~,p=0.001 n=6',
    }, '\n'))
    assert.same({ sig = false, text = 'p=0.818' }, stats['gob.Join-14'])
    assert.same({ sig = true, text = 'p=0.002' }, stats['gob.Sub/small-14'])
    assert.is_nil(stats.geomean)
  end)

  it('reads hyperfine 2 and 1.x JSON', function()
    local v2 = bench.parse_hyperfine({
      schema_version = 2,
      results = {
        {
          command = 'sleep 0.01',
          measurements = {},
          summary = {
            time_wall_clock = { unit = 'second', mean = 0.015, stddev = 0.002 },
            memory_peak_resident = { mean = 2e6 },
          },
        },
      },
    })
    assert.same({ { name = 'sleep 0.01', value = 0.015, stddev = 0.002 } }, v2)
    local v1 = bench.parse_hyperfine({
      results = { { command = 'ls', mean = 0.5, stddev = 0.1, times = {} } },
    })
    assert.same({ { name = 'ls', value = 0.5, stddev = 0.1 } }, v1)
  end)

  it('reads pytest-benchmark JSON', function()
    local benches = bench.parse_pytest({
      benchmarks = {
        {
          name = 'test_sort',
          fullname = 'tests/test_a.py::test_sort',
          stats = { mean = 0.002, stddev = 0.0001, rounds = 50 },
        },
        { name = 'broken', stats = {} },
      },
    })
    assert.same({
      { name = 'tests/test_a.py::test_sort', value = 0.002, stddev = 0.0001 },
    }, benches)
  end)

  it('reads the criterion benchmarks of this run, not older ones', function()
    local base = root .. '/target/criterion'
    local function crit(id, mean, change)
      local d = base .. '/' .. id
      h.write(d .. '/new/benchmark.json', {
        vim.json.encode({ full_id = id, title = id }),
      })
      h.write(d .. '/new/estimates.json', {
        vim.json.encode({
          mean = { point_estimate = mean },
          std_dev = { point_estimate = mean / 10 },
        }),
      })
      if change then
        h.write(d .. '/change/estimates.json', {
          vim.json.encode({
            mean = {
              point_estimate = 0.1,
              confidence_interval = {
                lower_bound = change[1],
                upper_bound = change[2],
              },
            },
          }),
        })
      end
    end
    crit('fib/20', 2000, { 0.05, 0.15 })
    crit('old', 1000)
    local past = os.time() - 3600
    vim.uv.fs_utime(base .. '/old/new/estimates.json', past, past)
    local benches = assert(bench.read_criterion(root, os.time() - 60))
    assert.same({
      {
        name = 'fib/20',
        value = 2000 / 1e9,
        stddev = 200 / 1e9,
        change = { 0.05, 0.15 },
      },
    }, benches)
    local none, err = bench.read_criterion(dir .. '/nothing', 0)
    assert.is_nil(none)
    assert.matches('No criterion results', err)
  end)

  local function result(id, key, benches, extra)
    return vim.tbl_extend('force', {
      id = id,
      tool = 'go test',
      key = key or 'go',
      label = '~/proj',
      root = root,
      time = 1700000000,
      benchmarks = benches or {},
    }, extra or {})
  end

  it('compares two results, regressions first and the worst first', function()
    local old = result('1', nil, {
      { name = 'a', value = 100 },
      { name = 'b', value = 100 },
      { name = 'c', value = 100 },
      { name = 'd', value = 100 },
      { name = 'e', value = 100 },
      { name = 'f', value = 100, stddev = 10 },
      { name = 'gone', value = 1 },
    })
    local new = result('2', nil, {
      { name = 'a', value = 110 },
      { name = 'b', value = 150 },
      { name = 'c', value = 80 },
      { name = 'd', value = 101 },
      { name = 'e', value = 130 },
      { name = 'f', value = 105, stddev = 8 },
      { name = 'fresh', value = 1 },
    })
    local rows = bench.compare(old, new, {
      e = { sig = false, text = 'p=0.4' },
    })
    local got = vim.tbl_map(
      function(r) return r.name .. ':' .. r.kind end,
      rows
    )
    assert.same({
      'b:regression',
      'a:regression',
      'c:improvement',
      'e:same', -- +30% but not significant
      'f:same', -- +5% inside the spread of a run
      'd:same',
      'fresh:added',
      'gone:removed',
    }, got)
    assert.same(50, rows[1].delta)
    assert.same(-20, rows[3].delta)
  end)

  it('lays the comparison out, regressions highlighted', function()
    local old = result('1', nil, { { name = 'a', value = 1e-6 } })
    local new =
      result('2', nil, { { name = 'a', value = 2e-6, stddev = 1e-7 } })
    local lines, hls = bench.lines(old, new, bench.compare(old, new))
    assert.same('# go test: ~/proj', lines[1])
    local last = lines[#lines]
    assert.matches('^a%s+1%.00 µs%s+2%.00 µs ±5%%%s+%+100%.0%%$', last)
    assert.same('DiagnosticError', hls[#lines - 1])
  end)

  it('never reads a first result as no change', function()
    local new = result('2', nil, { { name = 'a', value = 1 } })
    local lines = bench.lines(nil, new, bench.compare(nil, new))
    assert.matches('no earlier result', table.concat(lines, '\n'))
    assert.matches('added', lines[#lines])
    local old = result('1', nil, { { name = 'z', value = 1 } })
    lines = bench.lines(old, new, bench.compare(old, new))
    assert.matches('share no benchmark', table.concat(lines, '\n'))
  end)

  it('keeps the most recent results only', function()
    bench.KEEP = 2
    for i = 1, 4 do
      local r = result(('2026010%d'):format(i))
      h.write(bench.dir(root) .. '/' .. r.id .. '.raw', { 'x' })
      bench.save(root, r)
    end
    local ids = vim.tbl_map(function(r) return r.id end, bench.results(root))
    assert.same({ '20260103', '20260104' }, ids)
    assert.is_nil(vim.uv.fs_stat(bench.dir(root) .. '/20260101.raw'))
    assert.is_not_nil(vim.uv.fs_stat(bench.dir(root) .. '/20260104.raw'))
  end)

  --- A buffer of a Go project
  local function go_buffer()
    h.write(root .. '/go.mod', { 'module example.com/gob' })
    h.write(root .. '/b_test.go', { 'package gob' })
    vim.cmd.edit(root .. '/b_test.go')
    vim.bo.filetype = 'go'
  end

  it('says a missing tool and installs it, running nothing', function()
    bench.run_cmd('sleep 0')
    assert.is_true(noted('hyperfine is not installed', vim.log.levels.ERROR))
    assert.same({ 'hyperfine' }, installed)
    assert.same(0, #jobs)
    go_buffer()
    bench.run()
    assert.is_true(noted('go is not installed', vim.log.levels.ERROR))
    assert.same(0, #jobs)
  end)

  it('runs nothing in a project it is not trusted in', function()
    fake('go')
    go_buffer()
    trusted = false
    bench.run()
    assert.is_true(noted('not trusted', vim.log.levels.WARN))
    assert.same(1, asked)
    assert.same(0, #jobs)
  end)

  it('runs, keeps the result and compares it with the last', function()
    fake('go')
    go_buffer()
    on_job = function(cmd) h.write(cmd[6], GO_OUT) end
    bench.run()
    assert.is_true(vim.wait(2000, function() return #jobs == 1 end))
    assert.same('go', jobs[1].cmd[7])
    assert.is_true(noted('nothing earlier to compare with'))
    assert.same(1, #bench.results(root))

    -- Slower: a regression, with no benchstat to tell its significance
    on_job = function(cmd)
      h.write(cmd[6], {
        'pkg: example.com/gob',
        'BenchmarkJoin-14 \t 1\t 100.00 ns/op',
        'BenchmarkSub/small-14 \t 1\t 26.00 ns/op',
      })
    end
    vim.cmd('silent! tabonly | silent! only')
    vim.cmd.edit(root .. '/b_test.go')
    bench.run()
    assert.is_true(noted('1 slower than before', vim.log.levels.WARN))
    assert.same({ 'benchstat' }, installed)
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.matches('benchstat is not installed', table.concat(lines, '\n'))
    assert.matches('^gob%.Join%-14.*%+100%.0%%', lines[#lines - 1])
    local results = bench.results(root)
    assert.same(2, #results)
    assert.same(results[1].id, results[2].prev)
  end)

  it('keeps two runs of one second in their order', function()
    fake('go')
    go_buffer()
    on_job = function(cmd) h.write(cmd[6], GO_OUT) end
    local date, hrtime = os.date, vim.uv.hrtime
    -- The monotonic clock crosses a millisecond 1000 inside this second
    local mono, wall = { 999e6, 1000e6 }, { 998000, 999000 }
    local function from_bench()
      return debug.getinfo(3, 'S').source:match('tools/bench%.lua$')
    end
    vim.list_extend(restores, {
      h.stub(os, 'date', function(fmt, t)
        if fmt == '%Y%m%d-%H%M%S' then return '20260101-000000' end
        return date(fmt, t)
      end),
      -- `vim.wait` reads this clock too
      h.stub(
        vim.uv,
        'hrtime',
        function() return from_bench() and table.remove(mono, 1) or hrtime() end
      ),
      h.stub(
        vim.uv,
        'gettimeofday',
        function() return 1767225600, table.remove(wall, 1) end
      ),
    })
    bench.run()
    assert.is_true(noted('nothing earlier to compare with'))
    bench.run()
    assert.is_true(
      vim.wait(2000, function() return #bench.results(root) == 2 end)
    )
    local results = bench.results(root)
    assert.same(results[1].id, results[2].prev)
  end)

  it('keeps nothing of a failed or empty run', function()
    fake('go')
    go_buffer()
    exit_code = 1
    bench.run()
    assert.is_true(noted('exited 1: see its terminal', vim.log.levels.ERROR))
    exit_code = 0
    on_job = function(cmd) h.write(cmd[6], { 'PASS' }) end
    bench.run()
    assert.is_true(noted('ran no benchmark', vim.log.levels.ERROR))
    assert.same(0, #bench.results(root))
  end)

  it('compares the last two results of a kind, or says why not', function()
    go_buffer()
    bench.compare_cmd()
    assert.is_true(noted('No benchmark result kept', vim.log.levels.WARN))
    bench.save(root, result('1', nil, { { name = 'a', value = 1 } }))
    bench.save(
      root,
      result('2', 'hyperfine:ls', { { name = 'ls', value = 1 } })
    )
    bench.compare_cmd()
    assert.is_true(noted('Only one go test result', vim.log.levels.WARN))
    bench.save(
      root,
      result('3', 'hyperfine:ls', { { name = 'ls', value = 2 } })
    )
    bench.compare_cmd()
    assert.is_true(noted('1 slower than before', vim.log.levels.WARN))
  end)

  it('compares with the result recorded at a git ref', function()
    go_buffer()
    local sha = ('a'):rep(40)
    table.insert(
      restores,
      h.stub(package.loaded, 'util.system', {
        run = function(cmd, _, on_done)
          local known = cmd[5] == 'main^{commit}'
          on_done({ code = known and 0 or 128, stdout = sha .. '\n' })
        end,
      })
    )
    bench.save(
      root,
      result('1', nil, { { name = 'a', value = 1 } }, { head = sha })
    )
    bench.save(root, result('2', nil, { { name = 'a', value = 9 } }))
    bench.save(root, result('3', nil, { { name = 'a', value = 2 } }))
    bench.compare_cmd('nope')
    assert.is_true(noted('Not a git revision: nope', vim.log.levels.ERROR))
    bench.compare_cmd('main')
    assert.is_true(noted('1 slower than before', vim.log.levels.WARN))
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.matches('%+100%.0%%', lines[#lines])
  end)
end)
