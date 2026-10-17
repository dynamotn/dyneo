local h = require('helpers')

describe('util.system', function()
  local system, dir, cleanup
  before_each(function()
    h.unload('util.system')
    system = require('util.system')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function() cleanup() end)

  it('hands back what the command said', function()
    local result = system.sync(
      { 'sh', '-c', 'echo out; echo err >&2; exit 3' },
      {
        text = true,
      }
    )
    assert.are.equal(3, result.code)
    assert.are.equal('out\n', result.stdout)
    assert.are.equal('err\n', result.stderr)
  end)

  it('fails, not raises, on a command that is not there', function()
    local result = system.sync({ dir .. '/no-such-command' })
    assert.are.equal(127, result.code)
    assert.is_truthy(result.stderr:find('no-such-command', 1, true))
  end)

  it('hands back a result when its children outlive the deadline', function()
    -- The child holds the output open past the kill: `:wait()` alone gives nil
    h.write(dir .. '/slow', { '#!/bin/sh', 'sleep 5', 'echo late' })
    vim.fn.setfperm(dir .. '/slow', 'rwxr-xr-x')
    local start = vim.uv.hrtime()
    local result = system.sync({ dir .. '/slow' }, { timeout = 200 })
    local took = (vim.uv.hrtime() - start) / 1e6
    assert.are.equal(system.TIMED_OUT, result.code)
    assert.is_truthy(result.stderr:find('timed out', 1, true))
    assert.is_true(took < 2000, ('took %d ms'):format(took))
  end)

  it('runs nothing scheduled while it waits', function()
    local ran = false
    vim.schedule(function() ran = true end)
    system.sync({ 'sh', '-c', 'sleep 0.1' })
    assert.is_false(ran)
    vim.wait(100, function() return ran end)
  end)

  it('answers at the deadline, not twice the deadline', function()
    h.write(dir .. '/slow', { '#!/bin/sh', 'sleep 5', 'echo late' })
    vim.fn.setfperm(dir .. '/slow', 'rwxr-xr-x')
    local start = vim.uv.hrtime()
    system.sync({ dir .. '/slow' }, { timeout = 1000 })
    local took = (vim.uv.hrtime() - start) / 1e6
    assert.is_true(took < 1500, ('took %d ms'):format(took))
  end)

  it(
    'kills what a detached command started once it runs out of time',
    function()
      local marker = dir .. '/still-running'
      h.write(dir .. '/spawner', {
        '#!/bin/sh',
        '(sleep 1; touch "' .. marker .. '") &',
        'sleep 5',
      })
      vim.fn.setfperm(dir .. '/spawner', 'rwxr-xr-x')
      local result = system.sync(
        { dir .. '/spawner' },
        { timeout = 200, detach = true }
      )
      assert.are.equal(system.TIMED_OUT, result.code)
      vim.wait(1500)
      assert.are.equal(0, vim.fn.filereadable(marker))
    end
  )

  it('stops a command at the cap and says it was cut', function()
    local result = system.sync({ 'sh', '-c', 'yes' }, { max_bytes = 1000 })
    assert.is_true(result.cut)
    assert.is_false(result.timed_out)
    assert.are.equal(1000, #result.stdout + #result.stderr)
  end)

  it('keeps a stream the caller turned off out of the result', function()
    local result = system.sync({ 'sh', '-c', 'echo out' }, { stdout = false })
    assert.is_nil(result.stdout)
    assert.is_false(result.cut)
  end)

  describe('run', function()
    --- Run `cmd` and wait for its result, on the main loop
    local function run(cmd, opts)
      local result, on_main
      system.run(cmd, opts, function(r)
        on_main = not vim.in_fast_event()
        result = r
      end)
      assert.is_true(vim.wait(5000, function() return result ~= nil end, 10))
      assert.is_true(on_main)
      return result
    end

    it('hands back what the command said, on the main loop', function()
      local result = run({ 'sh', '-c', 'echo out; echo err >&2; exit 3' })
      assert.are.equal(3, result.code)
      assert.are.equal('out\n', result.stdout)
      assert.are.equal('err\n', result.stderr)
      assert.is_false(result.cut)
      assert.is_false(result.timed_out)
      assert.is_false(result.missing)
    end)

    it('says a command is not installed, later and without raising', function()
      local answered = false
      system.run({ dir .. '/nothing-here' }, {}, function() answered = true end)
      assert.is_false(answered)
      local result = run({ dir .. '/nothing-here' })
      assert.is_true(result.missing)
      assert.are.equal(system.MISSING, result.code)
      assert.is_truthy(
        system.failure(result):find('nothing-here is not installed', 1, true)
      )
    end)

    it('stops a command at the cap and says it was cut', function()
      local result = run({ 'sh', '-c', 'yes' }, { max_bytes = 1000 })
      assert.is_true(result.cut)
      assert.are.equal(1000, #result.stdout + #result.stderr)
    end)

    it('stops a command at the deadline and says so', function()
      local result = run({ 'sleep', '5' }, { timeout = 100 })
      assert.is_true(result.timed_out)
      assert.are.equal(
        'sleep gave no answer in time',
        system.failure(result, 'sleep')
      )
    end)

    it(
      'answers at the deadline though a child keeps the output open',
      function()
        h.write(dir .. '/holder', { '#!/bin/sh', 'sleep 10 &', 'sleep 10' })
        vim.fn.setfperm(dir .. '/holder', 'rwxr-xr-x')
        local restore = h.stub(system, 'GRACE', 100)
        local start = vim.uv.hrtime()
        local result = run({ dir .. '/holder' }, { timeout = 100 })
        restore()
        assert.is_true(result.timed_out)
        assert.is_true((vim.uv.hrtime() - start) / 1e6 < 3000)
      end
    )

    it('does not take a quick exit 124 for the deadline', function()
      local result = run({ 'sh', '-c', 'exit 124' }, { timeout = 5000 })
      assert.are.equal(124, result.code)
      assert.is_false(result.timed_out)
      assert.are.equal('sh exited 124', system.failure(result, 'sh'))
    end)

    it('lets go of its deadline timer once the command ends', function()
      local timers = {}
      local new_timer = vim.uv.new_timer
      local restore = h.stub(vim.uv, 'new_timer', function()
        local timer = new_timer()
        table.insert(timers, timer)
        return timer
      end)
      run({ 'true' }, { timeout = 60000 })
      restore()
      assert.is_true(#timers > 0)
      for _, timer in ipairs(timers) do
        assert.is_true(timer:is_closing())
      end
    end)

    it('feeds stdin and works in the directory given', function()
      local result = run(
        { 'sh', '-c', 'cat; pwd' },
        { stdin = 'in\n', cwd = dir }
      )
      assert.are.equal('in\n' .. dir .. '\n', result.stdout)
    end)
  end)

  describe('failure', function()
    it('names the exit when nothing was said', function()
      assert.are.equal(
        'git exited 2',
        system.failure({ code = 2, signal = 0, stderr = '  ' }, 'git')
      )
      assert.are.equal(
        'boom',
        system.failure({ code = 1, signal = 0, stderr = 'boom\n' }, 'git')
      )
    end)

    it(
      'says a run stopped at the output cap was cut',
      function()
        assert.are.equal(
          'helm printed more than can be read, and was stopped',
          system.failure(
            { code = 0, signal = 15, stderr = '', cut = true },
            'helm'
          )
        )
      end
    )
  end)

  describe('each', function()
    it('runs no more than the limit at once, and ends once', function()
      local running, most, seen, ended = 0, 0, {}, 0
      local pending = {}
      system.each({ 1, 2, 3, 4, 5 }, 2, function(item, done)
        running = running + 1
        most = math.max(most, running)
        table.insert(seen, item)
        table.insert(pending, function()
          running = running - 1
          done()
          done()
        end)
      end, function() ended = ended + 1 end)
      while #pending > 0 do
        table.remove(pending, 1)()
      end
      assert.are.equal(2, most)
      assert.are.same({ 1, 2, 3, 4, 5 }, seen)
      assert.are.equal(1, ended)
    end)

    it('goes on past a worker that raises', function()
      local ended, notes = false, {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      system.each({ 1, 2, 3 }, 1, function(item, done)
        if item == 2 then error('boom') end
        done()
      end, function() ended = true end)
      vim.wait(100, function() return #notes > 0 end)
      restore()
      assert.is_true(ended)
      assert.is_truthy(notes[1]:find('boom', 1, true))
    end)

    it('runs one at a time for a limit below 1', function()
      local seen = {}
      system.each({ 1, 2 }, 0, function(item, done)
        table.insert(seen, item)
        done()
      end)
      assert.are.same({ 1, 2 }, seen)
    end)

    it('ends at once for nothing to do', function()
      local ended = false
      system.each({}, 4, function() end, function() ended = true end)
      assert.is_true(ended)
    end)
  end)
end)
