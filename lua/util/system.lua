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
---
--- The exit is only reported once the output closes, and something the
--- command started can keep it open long after the command itself is gone,
--- past the deadline or past the cap. The answer is given without it then,
--- `M.GRACE` later, and whatever comes after is dropped.
---@param cmd string[]
---@param opts? DyRunOpts
---@param on_done fun(result: DyRunResult)
---@return vim.SystemObj? process Nil when it never started
function M.run(cmd, opts, on_done)
  opts = opts or {}
  local answered = false
  -- One timer for both: the deadline and, once stopped, the wait for the
  -- output to close
  local guard = assert(vim.uv.new_timer())
  ---@param result table
  local function finish(result)
    if answered then return end
    answered = true
    -- A command that ends in time leaves no timer behind until its deadline
    if not guard:is_closing() then
      guard:stop()
      guard:close()
    end
    -- `vim.system` turns CRLF into LF only in the output it collects itself,
    -- not in what it hands to readers like these
    if opts.text ~= false then
      result.stdout = result.stdout:gsub('\r\n', '\n')
      result.stderr = result.stderr:gsub('\r\n', '\n')
    end
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
  --- Answer with what was kept, `delay` from now, should the output still be
  --- open then
  ---@param delay integer Milliseconds
  ---@param code integer What the answer says the command exited with
  ---@param signal integer
  ---@param timed_out boolean
  local function answer_after(delay, code, signal, timed_out)
    guard:stop()
    guard:start(delay, 0, function()
      if answered then return end
      if process then stop(process, opts.detach) end
      finish({
        code = code,
        signal = signal,
        stdout = table.concat(streams.stdout),
        stderr = table.concat(streams.stderr),
        cut = cut,
        timed_out = timed_out,
        missing = false,
      })
    end)
  end
  local function reader(name)
    return function(_, data)
      if not data or cut then return end
      size = size + #data
      if size > max then
        cut = true
        data = data:sub(1, #data - (size - max))
        if process then
          stop(process, opts.detach)
          -- What a stopped command reports: no exit code, the signal
          answer_after(M.GRACE, 0, 15, false)
        end
      end
      table.insert(streams[name], data)
    end
  end

  local timeout = opts.timeout or M.RUN_TIMEOUT
  -- Loop time, the clock the deadline's own timer runs on
  local began = vim.uv.now()
  -- Set once the deadline stopped the command from here
  local deadline = false
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
    -- 124 is also a command's own exit code, `timeout(1)`'s say: only one
    -- that was killed, or ran until the deadline, was stopped by it
    local timed_out = not cut
      and (
        completed.code == M.TIMED_OUT
          and (completed.signal ~= 0 or vim.uv.now() - began >= timeout)
        or (deadline and completed.signal ~= 0)
      )
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
  -- `vim.system` stops the command at the deadline itself, but not what a
  -- detached one started, which goes with its group here; and the exit is
  -- only reported once the output closes, which something it started can
  -- hold open, so the answer is given without it `M.GRACE` later
  guard:start(timeout, 0, function()
    if answered then return end
    deadline = true
    stop(started, opts.detach)
    answer_after(M.GRACE, M.TIMED_OUT, 9, true)
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
  local timed_out = result.timed_out
  if timed_out == nil then timed_out = result.code == M.TIMED_OUT end
  if timed_out then return ('%s gave no answer in time'):format(name) end
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
  -- Below 1 nothing would ever start, and `on_done` never be called
  limit = math.max(1, math.floor(tonumber(limit) or 1))
  local next_index, running, finished = 0, 0, 0
  local start
  local function step(item)
    local called = false
    local function done()
      if called then return end
      called = true
      running = running - 1
      finished = finished + 1
      if finished == #items then
        if on_done then on_done() end
      else
        start()
      end
    end
    -- A worker that raises counts as done, or the rest would wait for it
    -- forever; the error is still said
    local ok, err = pcall(worker, item, done)
    if not ok then
      vim.schedule(
        function()
          vim.notify(('util.system.each: %s'):format(err), vim.log.levels.ERROR)
        end
      )
      done()
    end
  end
  -- A worker that calls `done` at once would start the next from inside this
  -- loop, one stack frame deeper per item: the loop already running takes it
  local looping = false
  start = function()
    if looping then return end
    looping = true
    -- `on_done` may raise from inside: the rest must not wait on the flag
    local ok, err = pcall(function()
      while running < limit and next_index < #items do
        next_index = next_index + 1
        running = running + 1
        step(items[next_index])
      end
    end)
    looping = false
    if not ok then error(err, 0) end
  end
  if #items == 0 then
    if on_done then on_done() end
    return
  end
  start()
end

---@class DySyncOpts: vim.SystemOpts
---@field timeout? integer Milliseconds, `M.TIMEOUT` unless given
---@field max_bytes? integer Output kept, `M.MAX_BYTES` unless given

---@class DySyncResult: vim.SystemCompleted
---@field cut boolean Stopped once its output passed `max_bytes`
---@field timed_out boolean Stopped at the deadline

--- Run `cmd` and wait for it, for no longer than `opts.timeout`
---
--- A command that cannot start, or runs out of time, comes back as a failed
--- result -- `code` 127 or `M.TIMED_OUT`, the reason in `stderr` -- never as
--- an error. One started with `detach` leads a process group of its own, and
--- the whole group is killed on a timeout, so nothing it started is left
--- running. Output read past `max_bytes` stops the command, as `run` does,
--- and the result says it was `cut`.
---@param cmd string[]
---@param opts? DySyncOpts
---@return DySyncResult
function M.sync(cmd, opts)
  opts = vim.deepcopy(opts or {})
  local timeout = opts.timeout or M.TIMEOUT
  -- The deadline is the wait's: a `timeout` in the options as well would
  -- have the process killed and still leave the wait without a result
  opts.timeout = nil
  local max = opts.max_bytes or M.MAX_BYTES
  opts.max_bytes = nil

  ---@type vim.SystemObj?
  local obj
  local size, cut = 0, false
  ---@type integer? Loop time the command was stopped at the cap
  local cut_at
  ---@type table<string, string[]>
  local kept = {}
  -- Streams the caller reads itself, or turned off, are left as they are
  for _, name in ipairs({ 'stdout', 'stderr' }) do
    if opts[name] == nil or opts[name] == true then
      kept[name] = {}
      opts[name] = function(_, data)
        if not data or cut then return end
        if opts.text then data = data:gsub('\r\n', '\n') end
        size = size + #data
        if size > max then
          cut, cut_at = true, vim.uv.now()
          data = data:sub(1, #data - (size - max))
          if obj then pcall(obj.kill, obj, 'sigterm') end
        end
        table.insert(kept[name], data)
      end
    end
  end

  ---@type vim.SystemCompleted?
  local result
  local started
  started, obj = pcall(
    vim.system,
    cmd,
    opts,
    function(completed) result = completed end
  )
  if not started then
    return {
      code = M.MISSING,
      signal = 0,
      stdout = '',
      stderr = tostring(obj),
      cut = false,
      timed_out = false,
    }
  end
  -- Not `obj:wait()`: past the deadline it kills the command and then waits
  -- as long again for the output something it started still holds open.
  -- Fast events only, as it does: nothing scheduled runs in the middle.
  -- A command stopped at the cap gets `M.GRACE` for its output to close.
  local ok, err = pcall(
    vim.wait,
    timeout,
    function()
      return result ~= nil
        or (cut_at ~= nil and vim.uv.now() - cut_at >= M.GRACE)
    end,
    nil,
    true
  )
  if ok and result then
    for name, chunks in pairs(kept) do
      result[name] = table.concat(chunks)
    end
    ---@cast result DySyncResult
    result.cut, result.timed_out = cut, false
    return result
  end
  if opts.detach and obj.pid then pcall(vim.uv.kill, -obj.pid, 'sigkill') end
  pcall(obj.kill, obj, 'sigkill')
  if ok and cut then
    -- Something the command started holds its output open: what was kept
    -- is the answer, as a stopped command reports it
    local answer = { code = 0, signal = 15, cut = true, timed_out = false }
    for name, chunks in pairs(kept) do
      answer[name] = table.concat(chunks)
    end
    return answer
  end
  return {
    code = M.TIMED_OUT,
    signal = 9,
    stdout = '',
    stderr = ok and ('timed out after %d ms'):format(timeout) or tostring(err),
    cut = cut,
    timed_out = true,
  }
end

return M
