--- External commands, run the one way the rules ask for
---
--- `run` is the usual way: in the background, with a deadline, its output
--- capped as it is read, and its answer handed over on the main loop. A
--- command that is not installed, cannot start or runs out of time comes back
--- as a failed result saying so -- never as an error, never as silence.
---
--- `sync` is for the few places nothing else will do: a file written through
--- `BufWriteCmd`, a reply the language server is waiting for, a plugin hook
--- that has to answer now. Those wait, always with a deadline, and always get
--- a result. `vim.system():wait()` gives back nil, not a result, when the
--- deadline passes while something the command started still holds its
--- output open -- a script running `sleep`, `sops` starting a `gpg-agent`.
local M = {}

--- The deadline of `sync` when none is given, in milliseconds
M.TIMEOUT = 5000

--- The deadline of `run` when none is given, in milliseconds
M.RUN_TIMEOUT = 60 * 1000

--- The output `run` keeps when no cap is given: stdout and stderr together
M.MAX_BYTES = 4 * 1024 * 1024

--- The exit code `timeout(1)` and `vim.system` give a command run out of time
M.TIMED_OUT = 124

--- How long past its deadline `run` waits for a command's output to close
M.GRACE = 1000

--- The exit code of a command that could not start
M.MISSING = 127

---@class DyRunOpts
---@field cwd? string
---@field env? table<string, string|number>
---@field clear_env? boolean
---@field stdin? string|string[]
---@field text? boolean `true` unless given
---@field timeout? integer Milliseconds, `M.RUN_TIMEOUT` unless given
---@field max_bytes? integer Output kept, `M.MAX_BYTES` unless given
---@field detach? boolean A process group of its own, stopped whole

---@class DyRunResult
---@field code integer
---@field signal integer
---@field stdout string
---@field stderr string
---@field cut boolean Stopped once its output passed `max_bytes`
---@field timed_out boolean Stopped at the deadline
---@field missing boolean Never started: not installed, or not runnable

--- Stop `process`, and what it started when it leads a group of its own
---@param process vim.SystemObj
---@param detach? boolean
local function stop(process, detach)
  if detach and process.pid then pcall(vim.uv.kill, -process.pid, 'sigterm') end
  pcall(process.kill, process, 'sigterm')
end

--- Run `cmd` in the background and hand `on_done` what it did, on the main
--- loop
---
--- Output is read as it comes and the command stopped once it passes
--- `max_bytes`: a log followed with `-f` or a query that never ends does not
--- fill the memory. What was kept comes back with `cut` set, which is not a
--- failure by itself -- the caller says it was cut.
---@param cmd string[]
---@param opts? DyRunOpts
---@param on_done fun(result: DyRunResult)
---@return vim.SystemObj? process Nil when it never started
function M.run(cmd, opts, on_done)
  opts = opts or {}
  local answered = false
  ---@param result table
  local function finish(result)
    if answered then return end
    answered = true
    vim.schedule(function() on_done(result) end)
  end
  local function never_started(reason)
    finish({
      code = M.MISSING,
      signal = 0,
      stdout = '',
      stderr = reason,
      cut = false,
      timed_out = false,
      missing = true,
    })
  end
  if vim.fn.executable(cmd[1]) ~= 1 then
    never_started(cmd[1] .. ' is not installed')
    return nil
  end

  local max = opts.max_bytes or M.MAX_BYTES
  local streams = { stdout = {}, stderr = {} }
  local size, cut = 0, false
  ---@type vim.SystemObj?
  local process
  local function reader(name)
    return function(_, data)
      if not data or cut then return end
      size = size + #data
      if size > max then
        cut = true
        data = data:sub(1, #data - (size - max))
        if process then stop(process, opts.detach) end
      end
      table.insert(streams[name], data)
    end
  end

  local timeout = opts.timeout or M.RUN_TIMEOUT
  local ok, started = pcall(vim.system, cmd, {
    cwd = opts.cwd,
    env = opts.env,
    clear_env = opts.clear_env,
    stdin = opts.stdin,
    text = opts.text ~= false,
    timeout = timeout,
    detach = opts.detach,
    stdout = reader('stdout'),
    stderr = reader('stderr'),
  }, function(completed)
    local timed_out = not cut and completed.code == M.TIMED_OUT
    -- The deadline stops the command itself; a detached one leaves what it
    -- started behind unless the group goes too
    if timed_out and opts.detach and process and process.pid then
      pcall(vim.uv.kill, -process.pid, 'sigkill')
    end
    finish({
      code = completed.code,
      signal = completed.signal,
      stdout = table.concat(streams.stdout),
      stderr = table.concat(streams.stderr),
      cut = cut,
      timed_out = timed_out,
      missing = false,
    })
  end)
  if not ok or not started then
    never_started(tostring(started))
    return nil
  end
  process = started
  -- The exit is only reported once the output closes, and something the
  -- command started can keep it open long past the deadline: the answer is
  -- given without it then, and whatever comes after is dropped
  local guard = assert(vim.uv.new_timer())
  guard:start(timeout + M.GRACE, 0, function()
    guard:close()
    if answered then return end
    stop(started, opts.detach)
    finish({
      code = M.TIMED_OUT,
      signal = 9,
      stdout = table.concat(streams.stdout),
      stderr = table.concat(streams.stderr),
      cut = cut,
      timed_out = true,
      missing = false,
    })
  end)
  return process
end

--- Why `result` failed, in one line for a notification
---@param result DyRunResult|vim.SystemCompleted
---@param name? string What ran, for the message
---@return string
function M.failure(result, name)
  name = name or 'the command'
  if result.missing then return result.stderr end
  if result.timed_out or result.code == M.TIMED_OUT then
    return ('%s gave no answer in time'):format(name)
  end
  if result.cut then
    return ('%s printed more than can be read, and was stopped'):format(name)
  end
  local err = vim.trim(result.stderr or '')
  if err ~= '' then return err end
  return ('%s exited %d'):format(name, result.code)
end

--- Run `worker` on each of `items`, no more than `limit` at a time, and call
--- `on_done` once every one of them has called its `done`
---
--- For a lookup per image, per action, per issue: all of them at once is a
--- burst of processes, and of requests to one host.
---@generic T
---@param items T[]
---@param limit integer
---@param worker fun(item: T, done: fun())
---@param on_done? fun()
function M.each(items, limit, worker, on_done)
  local next_index, running, finished = 0, 0, 0
  local function start()
    while running < limit and next_index < #items do
      next_index = next_index + 1
      running = running + 1
      local called = false
      worker(items[next_index], function()
        if called then return end
        called = true
        running = running - 1
        finished = finished + 1
        if finished == #items then
          if on_done then on_done() end
        else
          start()
        end
      end)
    end
  end
  if #items == 0 then
    if on_done then on_done() end
    return
  end
  start()
end

---@class DySyncOpts: vim.SystemOpts
---@field timeout? integer Milliseconds, `M.TIMEOUT` unless given

--- Run `cmd` and wait for it, for no longer than `opts.timeout`
---
--- A command that cannot start, or runs out of time, comes back as a failed
--- result -- `code` 127 or `M.TIMED_OUT`, the reason in `stderr` -- never as
--- an error. One started with `detach` leads a process group of its own, and
--- the whole group is killed on a timeout, so nothing it started is left
--- running.
---@param cmd string[]
---@param opts? DySyncOpts
---@return vim.SystemCompleted
function M.sync(cmd, opts)
  opts = vim.deepcopy(opts or {})
  local timeout = opts.timeout or M.TIMEOUT
  -- The deadline is the wait's: a `timeout` in the options as well would
  -- have the process killed and still leave the wait without a result
  opts.timeout = nil
  ---@type vim.SystemCompleted?
  local result
  local started, obj = pcall(
    vim.system,
    cmd,
    opts,
    function(completed) result = completed end
  )
  if not started then
    return { code = M.MISSING, signal = 0, stdout = '', stderr = tostring(obj) }
  end
  -- Not `obj:wait()`: past the deadline it kills the command and then waits
  -- as long again for the output something it started still holds open.
  -- Fast events only, as it does: nothing scheduled runs in the middle.
  local ok, err = pcall(
    vim.wait,
    timeout,
    function() return result ~= nil end,
    nil,
    true
  )
  if ok and result then return result end
  if opts.detach and obj.pid then pcall(vim.uv.kill, -obj.pid, 'sigkill') end
  pcall(obj.kill, obj, 'sigkill')
  return {
    code = M.TIMED_OUT,
    signal = 9,
    stdout = '',
    stderr = ok and ('timed out after %d ms'):format(timeout) or tostring(err),
  }
end

return M
