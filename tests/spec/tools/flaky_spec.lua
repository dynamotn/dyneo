local h = require('helpers')

describe('tools.flaky', function()
  local flaky, dir, root, cleanup, path, notes, restores, trusted

  before_each(function()
    h.unload('tools.flaky')
    flaky = require('tools.flaky')
    dir, cleanup = h.tmpdir()
    root = dir .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root, 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, trusted = {}, true
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level, opts)
          table.insert(notes, { msg = msg, level = level, opts = opts })
        end
      ),
      h.stub(package.loaded, 'util.trust', {
        ask = function() return trusted end,
      }),
    }
  end)
  after_each(function()
    if flaky.current then flaky.stop() end
    vim.wait(2000, function() return flaky.current == nil end)
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! tabonly')
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- A fake CLI `name` on the spec's `$PATH`, or at `at`
  local function fake(name, body, at)
    local file = at or (dir .. '/bin/' .. name)
    h.write(
      file,
      { '#!/bin/sh', unpack(vim.split(body, '\n', { plain = true })) }
    )
    vim.fn.setfperm(file, 'rwxr-xr-x')
  end

  local function noted(pattern, level)
    return vim.wait(5000, function()
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

  --- The report buffer's text, once a run is over
  local function report()
    assert.is_true(vim.wait(10000, function() return flaky.current == nil end))
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr):match('dyflaky://') then
        return table.concat(
          vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
          '\n'
        )
      end
    end
  end

  describe('summarize', function()
    it('says stable, flaky, always fails, and nothing run', function()
      local pass = { status = 'pass', ms = 1 }
      local fail = { status = 'fail', ms = 1, message = 'boom' }
      assert.equal('stable pass', flaky.summarize({ pass, pass }).verdict)
      assert.equal('flaky', flaky.summarize({ pass, fail }).verdict)
      assert.equal('always fails', flaky.summarize({ fail, fail }).verdict)
      assert.equal('no run finished', flaky.summarize({}).verdict)
    end)

    it(
      'counts distinct messages, most frequent first, and durations',
      function()
        local s = flaky.summarize({
          { status = 'pass', ms = 30 },
          { status = 'fail', ms = 10, message = 'b', output = 'first b' },
          { status = 'fail', ms = 20, message = 'a' },
          { status = 'fail', ms = 40, message = 'b', output = 'second b' },
          { status = 'timeout', ms = 50, message = 'timed out after 1 s' },
        })
        assert.equal(1, s.passes)
        assert.equal(5, s.runs)
        assert.equal(0.8, s.rate)
        assert.same(
          { 'b', 'a', 'timed out after 1 s' },
          vim.tbl_map(function(f) return f.message end, s.failures)
        )
        assert.equal(2, s.failures[1].count)
        assert.equal('first b', s.failures[1].output)
        assert.same({ 10, 30, 50 }, { s.min, s.median, s.max })
        assert.equal(
          25,
          flaky.summarize({
            { status = 'pass', ms = 20 },
            { status = 'pass', ms = 30 },
          }).median
        )
      end
    )
  end)

  describe('go_runs', function()
    local function event(t) return vim.json.encode(t) end

    it(
      'reads each iteration of every test, subtests counted with it',
      function()
        local stdout = table.concat({
          event({ Action = 'run', Test = 'TestA' }),
          event({ Action = 'pass', Test = 'TestA', Elapsed = 0.01 }),
          event({ Action = 'pass', Test = 'TestB', Elapsed = 0.02 }),
          event({ Action = 'run', Test = 'TestA' }),
          event({
            Action = 'output',
            Test = 'TestA/sub',
            Output = '=== RUN   TestA/sub\n',
          }),
          event({
            Action = 'output',
            Test = 'TestA/sub',
            Output = '    a_test.go:9: random failure\n',
          }),
          event({ Action = 'fail', Test = 'TestA/sub', Elapsed = 0 }),
          event({ Action = 'fail', Test = 'TestA', Elapsed = 0.03 }),
          event({ Action = 'pass', Test = 'TestB', Elapsed = 0.01 }),
          -- An iteration TestB never finished is not counted
          event({ Action = 'pass', Test = 'TestA', Elapsed = 0.01 }),
          event({ Action = 'fail', Elapsed = 1 }),
        }, '\n')
        local runs = assert(flaky.go_runs(stdout, { 'TestA', 'TestB' }))
        assert.equal(2, #runs)
        assert.equal('pass', runs[1].status)
        assert.equal(30, math.floor(runs[1].ms + 0.5))
        assert.equal('fail', runs[2].status)
        assert.equal('a_test.go:9: random failure', runs[2].message)
        assert.matches('random failure', runs[2].output)
      end
    )

    it('fails closed when no test ran, with what go said', function()
      local runs, err = flaky.go_runs(
        '# example.com/x\n./x.go:3:1: syntax error\nFAIL\texample.com/x [build failed]',
        { 'TestA' }
      )
      assert.is_nil(runs)
      assert.matches('syntax error', err)
      runs, err = flaky.go_runs('', { 'TestA' })
      assert.is_nil(runs)
      assert.equal('no test matched', err)
    end)
  end)

  describe('message', function()
    it('finds the first line of the failure of each tool', function()
      assert.equal(
        'assert 1 == 2',
        flaky.message(
          '..F\n    def test():\n>       assert 1 == 2\nE       assert 1 == 2\nE        +1',
          'python'
        )
      )
      assert.equal(
        'assertion `left == right` failed',
        flaky.message(
          "running 1 test\nthread 'tests::t' panicked at src/lib.rs:5:9:\nassertion `left == right` failed\n  left: 1",
          'rust'
        )
      )
      assert.equal(
        'expect(received).toBe(expected) // Object.is equality',
        flaky.message(
          ' FAIL  a.test.js\n  ● suite › works\n\n    expect(received).toBe(expected) // Object.is equality\n',
          'js'
        )
      )
      assert.equal('no output', flaky.message('\n\n', 'go'))
    end)
  end)

  describe('outcome', function()
    local function result(t)
      return vim.tbl_extend('keep', t, {
        code = 0,
        signal = 0,
        stdout = '',
        stderr = '',
        cut = false,
        timed_out = false,
        missing = false,
      })
    end

    it('counts a timeout and a cut output as failures', function()
      local run =
        flaky.outcome(result({ code = 124, timed_out = true }), 'python', 9)
      assert.equal('timeout', run.status)
      assert.matches('timed out', run.message)
      run = flaky.outcome(result({ cut = true }), 'python', 9)
      assert.equal('fail', run.status)
    end)

    it('gives no outcome for a test that cannot run', function()
      local run, err = flaky.outcome(
        result({
          code = 127,
          missing = true,
          stderr = 'pytest is not installed',
        }),
        'python',
        0
      )
      assert.is_nil(run)
      assert.equal('pytest is not installed', err)
      assert.is_nil((flaky.outcome(result({ code = 5 }), 'python', 0)))
      assert.is_nil(
        (flaky.outcome(result({ stdout = 'Tests: 3 skipped' }), 'js', 0))
      )
      assert.is_nil(
        (
          flaky.outcome(
            result({ stdout = 'test result: ok. 0 passed; 0 failed;' }),
            'rust',
            0
          )
        )
      )
      assert.is_nil(
        (
          flaky.outcome(
            result({ code = 101, stderr = 'error[E0425]' }),
            'rust',
            0
          )
        )
      )
      assert.equal(
        'pass',
        flaky.outcome(
          result({ stdout = 'test result: ok. 1 passed; 0 failed;' }),
          'rust',
          0
        ).status
      )
    end)
  end)

  describe('scan', function()
    it('finds the enclosing test of each language', function()
      local function names(lines, row, language)
        return vim.tbl_map(
          function(n) return n.name end,
          flaky.scan(lines, row, language) or {}
        )
      end
      assert.same(
        { 'TestA' },
        names(
          { 'package x', 'func TestA(t *testing.T) {', '  x()', '}' },
          3,
          'go'
        )
      )
      assert.same(
        { 'TestThing', 'test_it' },
        names(
          { 'class TestThing:', '    def test_it(self):', '        pass' },
          3,
          'python'
        )
      )
      assert.same(
        { 'adds (1 + 2)' },
        names({
          "describe('math', () => {",
          "  it('adds (1 + 2)', () => {",
          '    x()',
        }, 3, 'js')
      )
      assert.same(
        { 'tests', 'works' },
        names({
          'fn helper() {}',
          'mod tests {',
          '    #[test]',
          '    fn works() {',
          '        helper();',
        }, 5, 'rust')
      )
      assert.same({}, names({ 'fn helper() {', '  x', '}' }, 2, 'rust'))
    end)
  end)

  describe('command', function()
    it('runs one go test with -count and its tests anchored', function()
      local c = flaky.command({
        language = 'go',
        root = root,
        file = 'pkg/a_test.go',
        names = { 'TestA', 'TestB' },
        label = 'x',
      }, 7)
      assert.is_true(c.json)
      assert.is_true(vim.tbl_contains(c.cmd, '-count=7'))
      assert.is_true(vim.tbl_contains(c.cmd, '^(TestA|TestB)$'))
      assert.equal('./pkg', c.cmd[#c.cmd])
    end)

    it('names a Rust test by its full path, exactly', function()
      local c = flaky.command({
        language = 'rust',
        root = root,
        file = 'src/net/mod.rs',
        chain = {
          { kind = 'namespace', name = 'tests' },
          { kind = 'test', name = 't' },
        },
        label = 'x',
      }, 3)
      assert.same({ 'cargo', 'test', '--', '--exact', 'net::tests::t' }, c.cmd)
    end)

    it('escapes a JavaScript name and fails without a runner', function()
      local target = {
        language = 'js',
        root = root,
        file = 'a.test.js',
        chain = { { kind = 'test', name = 'adds (1 + 2)' } },
        label = 'x',
      }
      local c, err = flaky.command(target, 3)
      assert.is_nil(c)
      assert.matches('jest', err)
      fake('vitest', 'exit 0', root .. '/node_modules/.bin/vitest')
      c = assert(flaky.command(target, 3))
      assert.equal('adds \\(1 \\+ 2\\)', c.cmd[#c.cmd])
    end)

    it('keeps pytest-randomly when the project uses it', function()
      local target = {
        language = 'python',
        root = root,
        file = 't_test.py',
        chain = { { kind = 'test', name = 'test_x' } },
        label = 'x',
      }
      assert.is_true(
        vim.tbl_contains(flaky.command(target, 1).cmd, 'no:randomly')
      )
      h.write(root .. '/requirements-dev.txt', { 'pytest-randomly' })
      assert.is_false(
        vim.tbl_contains(flaky.command(target, 1).cmd, 'no:randomly')
      )
      assert.equal(
        't_test.py::test_x',
        flaky.command(target, 1).cmd[#flaky.command(target, 1).cmd]
      )
    end)
  end)

  describe('running', function()
    local function python_target()
      return {
        language = 'python',
        root = root,
        file = 'test_a.py',
        chain = { { kind = 'test', name = 'test_a' } },
        label = 'test_a.py test_a',
      }
    end

    it('runs pytest each time and reports a flaky test', function()
      -- Fails every third run
      fake(
        'pytest',
        table.concat({
          'n=$(cat "'
            .. dir
            .. '/n" 2>/dev/null || echo 0); n=$((n+1)); echo $n > "'
            .. dir
            .. '/n"',
          'echo "$@" >> "' .. dir .. '/args"',
          'if [ $((n % 3)) -eq 0 ]; then echo "E   assert 0 == 1"; exit 1; fi',
          'echo "1 passed"',
        }, '\n')
      )
      flaky.start(python_target(), 6)
      local text = report()
      assert.matches('Verdict: %*%*flaky%*%*', text)
      assert.matches('Passed: 4 of 6 %(33%% failed%)', text)
      assert.matches('%- 2x assert 0 == 1', text)
      assert.matches('Durations: min', text)
      assert.equal(6, #vim.fn.readfile(dir .. '/args'))
      assert.matches('test_a.py::test_a', vim.fn.readfile(dir .. '/args')[1])
      assert.is_true(noted('flaky, 4 of 6 passed', vim.log.levels.WARN))
    end)

    it('reads one go test -json run', function()
      local lines = {}
      for i = 1, 4 do
        table.insert(lines, vim.json.encode({ Action = 'run', Test = 'TestA' }))
        table.insert(
          lines,
          vim.json.encode({
            Action = i == 2 and 'fail' or 'pass',
            Test = 'TestA',
            Elapsed = 0.01,
          })
        )
      end
      h.write(dir .. '/go.json', lines)
      fake(
        'go',
        'echo "$@" > "' .. dir .. '/args"; cat "' .. dir .. '/go.json"; exit 1'
      )
      flaky.start({
        language = 'go',
        root = root,
        file = 'a_test.go',
        names = { 'TestA' },
        label = 'a_test.go TestA',
      }, 4)
      local text = report()
      assert.matches('Passed: 3 of 4', text)
      assert.matches('%*%*flaky%*%*', text)
      assert.matches('%-count=4', vim.fn.readfile(dir .. '/args')[1])
    end)

    it('says a missing tool, never a pass', function()
      flaky.start(python_target(), 3)
      assert.is_true(
        noted('not run: pytest is not installed', vim.log.levels.ERROR)
      )
      assert.is_nil(flaky.current)
      assert.is_nil(report())
    end)

    it('counts a run past its deadline as a failure', function()
      flaky.TIMEOUT = 200
      fake('pytest', 'sleep 5')
      flaky.start(python_target(), 2)
      local text = report()
      assert.matches('%*%*always fails%*%*', text)
      assert.matches('2x timed out', text)
    end)

    it('stops early and reports only the runs that finished', function()
      fake(
        'pytest',
        table.concat({
          'if [ -e "' .. dir .. '/once" ]; then sleep 5; fi',
          'touch "' .. dir .. '/once"; echo "1 passed"',
        }, '\n')
      )
      flaky.start(python_target(), 5)
      assert.is_true(
        vim.wait(
          5000,
          function()
            return vim.uv.fs_stat(dir .. '/once') ~= nil
              and flaky.current.process ~= nil
              and noted('run 2 of 5')
          end
        )
      )
      flaky.stop()
      local text = report()
      assert.matches('Passed: 1 of 1', text)
      assert.matches('Ended after 1 of 5: stopped', text)
    end)

    it('runs a faked jest and cargo', function()
      fake(
        'jest',
        'echo "Tests: 1 passed, 1 total"',
        root .. '/node_modules/.bin/jest'
      )
      flaky.start({
        language = 'js',
        root = root,
        file = 'a.test.js',
        chain = { { kind = 'test', name = 'works' } },
        label = 'a.test.js works',
      }, 2)
      assert.matches('%*%*stable pass%*%*', report())
      vim.cmd('silent! tabonly')
      fake(
        'cargo',
        'echo "test result: FAILED. 0 passed; 1 failed; 0 ignored"; exit 101'
      )
      flaky.start({
        language = 'rust',
        root = root,
        file = 'src/lib.rs',
        chain = { { kind = 'test', name = 'works' } },
        label = 'src/lib.rs works',
      }, 2)
      local found
      assert.is_true(vim.wait(5000, function()
        for _, note in ipairs(notes) do
          if note.msg:match('src/lib.rs works: always fails') then
            found = true
          end
        end
        return found
      end))
    end)
  end)

  describe('run', function()
    it('asks for trust, and runs the test under the cursor', function()
      h.write(root .. '/pyproject.toml', {})
      h.write(root .. '/test_a.py', { 'def test_a():', '    assert True' })
      vim.cmd.edit(root .. '/test_a.py')
      vim.bo.filetype = 'python'
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      trusted = false
      flaky.run('', 0)
      assert.is_true(noted('not trusted', vim.log.levels.WARN))
      trusted = true
      fake('pytest', 'echo "$@" > "' .. dir .. '/args"; echo "1 passed"')
      flaky.run('', 2)
      assert.matches('Passed: 2 of 2', report())
      assert.matches('test_a.py::test_a', vim.fn.readfile(dir .. '/args')[1])
    end)

    it('refuses a second run and an unknown filetype', function()
      flaky.current = { stopped = false }
      flaky.run('', 0)
      assert.is_true(noted('going on', vim.log.levels.WARN))
      flaky.current = nil
      vim.bo.filetype = 'text'
      flaky.run('file', 0)
      assert.is_true(
        noted('No flaky%-test run for filetype', vim.log.levels.ERROR)
      )
    end)
  end)
end)
