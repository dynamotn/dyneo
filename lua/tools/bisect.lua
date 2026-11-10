--- Bisect: the commit that broke a check, found by `git bisect run`
---
--- The run never touches the working tree, index or branch of the user: it
--- happens in a throwaway detached worktree under the cache directory (bisect
--- state is per worktree), removed again once the run ends, fails, times out,
--- is stopped, or Neovim quits. The check therefore runs against committed
--- code only. Before bisecting, the check runs once at the bad commit (it must
--- fail) and once at the good one (it must pass), so a run that could only
--- give a wrong answer says why instead. The first bad commit opens as
--- `git show` in a scratch tab.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('Bisect')

--- Milliseconds the whole run may take
M.TIMEOUT = 30 * 60 * 1000

--- Milliseconds a git command of the setup or cleanup may take
M.GIT_TIMEOUT = 30 * 1000

--- Output kept of `git bisect log` and `git show`
M.MAX_BYTES = 4 * 1024 * 1024

--- Lines of a step's output shown in the terminal: its tail
M.STEP_LINES = 200

--- Lines of the terminal split
M.HEIGHT = 15

--- Exit codes of the driver script, before `git bisect run` starts
M.EXIT = {
  passes_at_bad = 90,
  cannot_run_at_bad = 91,
  checkout = 92,
  fails_at_good = 93,
  start = 94,
}

--- One check step: the command, its output kept in a file and only its tail
--- printed, its exit code passed on to `git bisect run`
local STEP = [[
sh -c "$DY_BISECT_CMD" >"$DY_BISECT_OUT" 2>&1
rc=$?
tail -n "$DY_BISECT_LINES" "$DY_BISECT_OUT"
printf '[exit %s]\n' "$rc"
exit "$rc"
]]

--- The run in the worktree, at the bad commit when it starts
local DRIVER = [[
printf '== the check at the bad commit %s\n' "$DY_BISECT_BAD"
sh -c "$DY_BISECT_STEP"
rc=$?
[ "$rc" -eq 0 ] && exit 90
{ [ "$rc" -eq 125 ] || [ "$rc" -ge 128 ]; } && exit 91
git checkout -q -f --detach "$DY_BISECT_GOOD" || exit 92
printf '\n== the check at the good commit %s\n' "$DY_BISECT_GOOD"
sh -c "$DY_BISECT_STEP" || exit 93
printf '\n== git bisect\n'
git bisect start "$DY_BISECT_BAD" "$DY_BISECT_GOOD" >/dev/null || exit 94
git bisect run sh -c "$DY_BISECT_STEP"
]]

---@class DyBisectRun
---@field root string The repository of the user
---@field path string The worktree made for the run
---@field good string
---@field bad string
---@field cmd string
---@field job? integer
---@field timer? uv.uv_timer_t
---@field note? string Why it ended early: stopped, timed out
---@field done? boolean

--- The run going on, nil when none
---@type DyBisectRun?
M.current = nil

--- The last check command used, per repository, for the session
---@type table<string, string>
M.last_cmd = {}

--- `text` quoted for a POSIX shell
---@param text string
---@return string
function M.quote(text)
  if text:match('^[%w%._/:=,+@%-]+$') then return text end
  return "'" .. text:gsub("'", [['\'']]) .. "'"
end

--- Where the worktrees of runs go
---@return string
function M.base()
  return vim.fs.joinpath(vim.fn.stdpath('cache'), 'dyneo', 'bisect')
end

--- Whether `path` is a worktree path this module makes: a direct child of
--- `M.base()` with a name, so a removal can never reach anything else
---@param path any
---@return boolean
function M.owned(path)
  if type(path) ~= 'string' or path == '' then return false end
  local base = vim.fs.normalize(M.base())
  local name = path:sub(#base + 2)
  return path:sub(1, #base + 1) == base .. '/' and name:match('^[%x]+$') ~= nil
end

--- Run git with `args` in `cwd`
---@param cwd string
---@param args string[]
---@param on_done fun(result: DyRunResult)
local function git(cwd, args, on_done)
  system.run(
    vim.list_extend({ 'git' }, args),
    { cwd = cwd, timeout = M.GIT_TIMEOUT, max_bytes = M.MAX_BYTES },
    on_done
  )
end

--- Remove the worktree of `run` and its bisect state; waits when `wait`
--- (quitting), else answers `on_done` from the background
---@param run DyBisectRun
---@param wait? boolean
---@param on_done? fun(err?: string)
local function cleanup(run, wait, on_done)
  if run.timer and not run.timer:is_closing() then run.timer:close() end
  pcall(vim.api.nvim_del_augroup_by_name, 'dy_bisect')
  if M.current == run then M.current = nil end
  on_done = on_done or function() end
  if not M.owned(run.path) then
    return on_done(
      ('Not removed: %s is not a bisect worktree'):format(run.path)
    )
  end
  local out = run.path .. '.out'
  local steps = {
    { 'git', '-C', run.path, 'bisect', 'reset' },
    { 'git', '-C', run.root, 'worktree', 'remove', '--force', run.path },
  }
  local function removed(result)
    vim.fn.delete(out)
    if result.code ~= 0 and vim.uv.fs_stat(run.path) then
      return on_done(
        ('The worktree %s is left: %s'):format(
          run.path,
          system.failure(result, 'git worktree remove')
        )
      )
    end
    on_done()
  end
  if wait then
    system.sync(steps[1], { timeout = M.GIT_TIMEOUT })
    return removed(system.sync(steps[2], { timeout = M.GIT_TIMEOUT }))
  end
  system.run(
    steps[1],
    { timeout = M.GIT_TIMEOUT },
    function() system.run(steps[2], { timeout = M.GIT_TIMEOUT }, removed) end
  )
end

--- The first bad commit `git bisect log` names, or nil and what it says
--- instead: the candidates when only skipped commits were left
---@param log string
---@return string? sha
---@return string[] candidates
function M.parse_log(log)
  local candidates = {}
  for line in vim.gsplit(log, '\n', { plain = true }) do
    -- `bad` quoted by git 2.47 and later, bare before
    local sha = line:match("^# first '?bad'? commit: %[(%x+)%]")
    if sha then return sha, {} end
    local possible = line:match("^# possible first '?bad'? commit: %[(%x+)%]")
    if possible then table.insert(candidates, possible) end
  end
  return nil, candidates
end

--- Open commit `sha` of `root` in a scratch tab and say who made it, when
---@param root string
---@param sha string
function M.show_commit(root, sha)
  git(root, {
    'show',
    '--no-color',
    '--no-ext-diff',
    '--stat',
    '--patch',
    '--date=short',
    '--format=commit %H%nAuthor: %an <%ae>%nDate:   %ad%n%n    %s%n%n%b',
    sha,
  }, function(result)
    if result.code ~= 0 and not result.cut then
      return notify(
        ('The first bad commit is %s; %s'):format(
          sha,
          system.failure(result, 'git show')
        ),
        vim.log.levels.ERROR
      )
    end
    local lines = vim.split(result.stdout, '\n', { plain = true })
    if result.cut then
      table.insert(
        lines,
        ('… cut at %d MiB'):format(M.MAX_BYTES / 1024 / 1024)
      )
    end
    require('util.scratch').open(lines, {
      filetype = 'git',
      name = 'dybisect://' .. sha,
    })
    local author = (lines[2] or ''):match('^Author: (.-) <') or '?'
    local date = (lines[3] or ''):match('^Date:%s+(.*)$') or '?'
    notify(
      ('First bad commit %s %s\n%s, %s'):format(
        sha:sub(1, 12),
        vim.trim(lines[5] or ''),
        author,
        date
      ),
      vim.log.levels.WARN
    )
  end)
end

--- Say what the run that exited `code` found, then clean up
---@param run DyBisectRun
---@param code integer
local function finished(run, code)
  if run.done then return end
  run.done = true
  local function report(msg, level, sha)
    cleanup(run, false, function(err)
      if err then notify(err, vim.log.levels.ERROR) end
      notify(msg, level)
      if sha then M.show_commit(run.root, sha) end
    end)
  end
  if run.note then
    return report(
      ('Bisect %s: no first bad commit found'):format(run.note),
      vim.log.levels.WARN
    )
  end
  local short = function(sha) return sha:sub(1, 12) end
  local known = {
    [M.EXIT.passes_at_bad] = ('The check passes at the bad commit %s: there is no breakage to find'):format(
      short(run.bad)
    ),
    [M.EXIT.cannot_run_at_bad] = ('The check cannot run at the bad commit %s (it exited 125 or 128 and above): see the terminal'):format(
      short(run.bad)
    ),
    [M.EXIT.checkout] = ('Could not check out the good commit %s: see the terminal'):format(
      short(run.good)
    ),
    [M.EXIT.fails_at_good] = ('The check fails at the good commit %s already: give an older good ref'):format(
      short(run.good)
    ),
    [M.EXIT.start] = 'git bisect start failed: see the terminal',
  }
  if known[code] then return report(known[code], vim.log.levels.ERROR) end
  git(run.path, { 'bisect', 'log' }, function(result)
    local sha, candidates = M.parse_log(result.stdout or '')
    if sha and code == 0 then
      return report(
        ('Bisect done: %s is the first bad commit'):format(short(sha)),
        vim.log.levels.INFO,
        sha
      )
    end
    if #candidates > 0 then
      return report(
        ('Only skipped commits are left (exit 125): the first bad one is among %d: %s'):format(
          #candidates,
          table.concat(vim.tbl_map(short, candidates), ', ')
        ),
        vim.log.levels.WARN
      )
    end
    report(
      ('git bisect run stopped with exit %d and named no first bad commit: see the terminal'):format(
        code
      ),
      vim.log.levels.ERROR
    )
  end)
end

--- Stop the run going on; its worktree is removed
---@param note? string Why, `stopped` unless given
function M.stop(note)
  local run = M.current
  if not run then return notify('No bisect going on') end
  run.note = note or 'stopped'
  -- The terminal job ends, its `on_exit` reports and cleans up; before it
  -- starts, the setup sees the note and stops there
  if run.job then pcall(vim.fn.jobstop, run.job) end
end

--- Resolve `ref` of `root` to a commit
---@param root string
---@param ref string
---@param on_done fun(sha?: string, err?: string)
local function resolve(root, ref, on_done)
  git(root, {
    'rev-parse',
    '--verify',
    '--quiet',
    '--end-of-options',
    ref .. '^{commit}',
  }, function(result)
    local sha = vim.trim(result.stdout or '')
    if result.code ~= 0 or sha == '' then
      return on_done(nil, ('%q is not a commit of %s'):format(ref, root))
    end
    on_done(sha)
  end)
end

--- Start the terminal run of `run`, its worktree made
---@param run DyBisectRun
local function launch(run)
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup('dy_bisect', { clear = true }),
    callback = function()
      local current = M.current
      if not current then return end
      current.done = true
      if current.job then
        pcall(vim.fn.jobstop, current.job)
        pcall(vim.fn.jobwait, { current.job }, 2000)
      end
      cleanup(current, true)
    end,
  })
  run.timer = vim.defer_fn(function()
    if M.current == run then M.stop('timed out') end
  end, M.TIMEOUT)
  vim.cmd('botright ' .. M.HEIGHT .. 'split')
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, buf)
  local env = {
    DY_BISECT_CMD = run.cmd,
    DY_BISECT_GOOD = run.good,
    DY_BISECT_BAD = run.bad,
    DY_BISECT_OUT = run.path .. '.out',
    DY_BISECT_LINES = tostring(M.STEP_LINES),
    DY_BISECT_STEP = STEP,
  }
  local ok, job = pcall(vim.fn.jobstart, { 'sh', '-c', DRIVER }, {
    term = true,
    cwd = run.path,
    env = env,
    on_exit = function(_, code)
      vim.schedule(function() finished(run, code) end)
    end,
  })
  if not ok or type(job) ~= 'number' or job <= 0 then
    run.note = 'could not start'
    return finished(run, -1)
  end
  run.job = job
  vim.cmd.startinsert()
end

--- Bisect `root` from `good` to `bad` with shell command `cmd`
---@param root string
---@param good string
---@param bad string
---@param cmd string
function M.start(root, good, bad, cmd)
  if M.current then
    return notify(
      'A bisect is going on: `:DyBisect stop` ends it',
      vim.log.levels.WARN
    )
  end
  if vim.trim(cmd) == '' then
    return notify('No check command: nothing to run', vim.log.levels.ERROR)
  end
  local question = ('Bisect %s with `%s`?\nIt runs the check at old commits of the project, as you.'):format(
    vim.fn.fnamemodify(root, ':~'),
    cmd
  )
  if not require('util.trust').ask('bisect', root, question) then
    return notify('Not run: the project is not trusted', vim.log.levels.WARN)
  end
  M.last_cmd[root] = cmd
  -- Taken now, so a second start while git answers is refused
  ---@type DyBisectRun
  local run = { root = root, good = good, bad = bad, cmd = cmd, path = '' }
  M.current = run
  local function fail(msg)
    if M.current == run then M.current = nil end
    notify(msg, vim.log.levels.ERROR)
  end
  resolve(root, bad, function(bad_sha, bad_err)
    if not bad_sha then return fail(bad_err) end
    resolve(root, good, function(good_sha, good_err)
      if not good_sha then return fail(good_err) end
      if good_sha == bad_sha then
        return fail(('%s and %s are the same commit'):format(good, bad))
      end
      git(
        root,
        { 'merge-base', '--is-ancestor', good_sha, bad_sha },
        function(ancestor)
          if ancestor.code ~= 0 then
            return fail(
              ancestor.code == 1
                  and ('%s is not an ancestor of %s: give a good ref older than the bad one'):format(
                    good,
                    bad
                  )
                or system.failure(ancestor, 'git merge-base')
            )
          end
          if run.note then return fail('Bisect stopped') end
          run.good, run.bad = good_sha, bad_sha
          local base = M.base()
          vim.fn.mkdir(base, 'p')
          run.path = vim.fs.joinpath(
            vim.fs.normalize(base),
            vim.fn.sha256(root .. vim.uv.hrtime()):sub(1, 12)
          )
          git(
            root,
            { 'worktree', 'add', '--detach', run.path, bad_sha },
            function(added)
              if added.code ~= 0 then
                -- A half-made one goes too
                cleanup(run, false)
                return fail(system.failure(added, 'git worktree add'))
              end
              if run.note then return finished(run, -1) end
              launch(run)
            end
          )
        end
      )
    end)
  end)
end

--- The repository of the current buffer, else of the working directory
---@return string?
local function repo_root()
  local name = vim.api.nvim_buf_get_name(0)
  local root = vim.fs.root(name ~= '' and name or vim.fn.getcwd(), '.git')
    or vim.fs.root(vim.fn.getcwd(), '.git')
  return root and (vim.uv.fs_realpath(root) or root)
end

--- The check of the test under the cursor, through the command builder of
--- `:DyFlaky`, run from its project directory; nil when there is none
---@param root string
---@return string?
function M.test_command(root)
  local flaky = require('tools.flaky')
  local ok, target = pcall(flaky.target, vim.api.nvim_get_current_buf())
  if not ok or not target then return nil end
  local command = flaky.command(target, 1)
  if not command or not require('util.root').contains(root, target.root) then
    return nil
  end
  local words = vim.tbl_map(
    M.quote,
    -- One readable line per step in the terminal
    vim.tbl_filter(function(w) return w ~= '-json' end, command.cmd)
  )
  local sub = target.root:sub(#root + 2)
  local line = table.concat(words, ' ')
  return sub == '' and line or ('cd %s && %s'):format(M.quote(sub), line)
end

--- The default good ref: the merge base with the default branch, else the
--- last tag before `bad`
---@param root string
---@param bad string
---@param on_done fun(ref: string)
local function default_good(root, bad, on_done)
  require('tools.testaffected').base(root, nil, function(merge_base)
    resolve(root, bad, function(bad_sha)
      if merge_base and merge_base ~= bad_sha then
        return on_done(merge_base)
      end
      git(
        root,
        { 'describe', '--tags', '--abbrev=0', '--end-of-options', bad .. '^' },
        function(result)
          on_done(result.code == 0 and vim.trim(result.stdout) or '')
        end
      )
    end)
  end)
end

--- `:DyBisect [{good} [{bad}]] [-- {cmd}]` and `:DyBisect stop`: what is
--- not given is asked, prefilled
---@param args string
function M.command(args)
  args = vim.trim(args or '')
  if args == 'stop' then return M.stop() end
  local refs, cmd = args:match('^(.-)%s*%-%-%s+(.*)$')
  if not refs then refs = args:match('^(.-)%s*%-%-$') or args end
  local words = vim.split(refs, '%s+', { trimempty = true })
  if #words > 2 then
    return notify(
      'Usage: `:DyBisect [{good} [{bad}]] [-- {cmd}]`',
      vim.log.levels.ERROR
    )
  end
  local root = repo_root()
  if not root then
    return notify('Not in a git repository', vim.log.levels.ERROR)
  end
  local bad = words[2] or 'HEAD'
  local function ask_cmd(good)
    if cmd and cmd ~= '' then return M.start(root, good, bad, cmd) end
    vim.ui.input({
      prompt = 'Check (exit 0 good, 125 skip, else bad): ',
      default = M.test_command(root) or M.last_cmd[root] or '',
    }, function(input)
      if input and vim.trim(input) ~= '' then
        M.start(root, good, bad, input)
      end
    end)
  end
  if words[1] then return ask_cmd(words[1]) end
  default_good(root, bad, function(ref)
    vim.ui.input(
      { prompt = ('Good ref (bad is %s): '):format(bad), default = ref },
      function(input)
        if input and vim.trim(input) ~= '' then ask_cmd(vim.trim(input)) end
      end
    )
  end)
end

return M
