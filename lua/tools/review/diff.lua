--- The diff of one file of a review, shown by codediff.nvim
---
--- codediff has no public API to open a diff and hand back its buffers, so
--- this is the one module that touches its internals: the `:CodeDiff file`
--- command run from the worktree file's buffer (so the new side is that real
--- file, where language servers attach once the review is trusted), its
--- `User` events, and `codediff.ui.lifecycle` for the buffers and windows of
--- a diff tab. Every internal call is guarded; when one stops working the
--- user is told "codediff changed: <what>" and the diff still opens, both
--- sides read from git, without drafts drawn on it.
local M = {}

local notify = require('util.notify').titled('Review')

--- How long a new diff tab is waited for, and how often it is asked, in ms
M.CLAIM_TIMEOUT = 5000
M.CLAIM_INTERVAL = 50

---@alias DyReviewSide 'old'|'new'

---@class DyReviewDiffState
---@field tab? integer The diff tab of the review
---@field path? string The file it shows
---@field old? integer
---@field new? integer
---@field want? string The file asked for, until its diff opens

---@type DyReviewDiffState
local current = {}

---@type fun(bufnr: integer, path: string, side: DyReviewSide)?
local handler

--- Say that codediff no longer works the way this module expects
---@param what string
local function changed(what)
  notify('codediff changed: ' .. what, vim.log.levels.WARN)
end

--- `codediff.ui.lifecycle`, nil (and said) when it is gone or different
---@return table?
local function lifecycle()
  local ok, module = pcall(require, 'codediff.ui.lifecycle')
  if
    not ok
    or type(module) ~= 'table'
    or type(module.get_buffers) ~= 'function'
    or type(module.get_windows) ~= 'function'
  then
    changed('codediff.ui.lifecycle has no get_buffers or get_windows')
    return nil
  end
  return module
end

--- Hand one side's buffer to the handler
---@param bufnr? integer
---@param side DyReviewSide
local function fire(bufnr, side)
  if not (handler and bufnr and current.path) then return end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  handler(bufnr, current.path, side)
end

--- Whether buffer `bufnr` shows `path`: the real file, or a `codediff://`
--- buffer of it
---@param bufnr? integer
---@param path string
---@return boolean
local function shows(bufnr, path)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return false end
  local name = vim.api.nvim_buf_get_name(bufnr)
  return name:sub(-#path - 1) == '/' .. path
end

--- Take diff tab `tab` as the review's when it shows `path`
---@param tab integer
---@param path string
---@return 'taken'|'wait'|'other' # `wait` while codediff has not recorded it
local function claim(tab, path)
  local module = lifecycle()
  if not module then return 'other' end
  local ok, old, new = pcall(module.get_buffers, tab)
  if not ok then
    changed('get_buffers failed: ' .. tostring(old))
    return 'other'
  end
  if not (old or new) then return 'wait' end
  if not (shows(new, path) or shows(old, path)) then return 'other' end
  local previous = current.tab
  current = { tab = tab, path = path, old = old, new = new }
  if
    previous
    and previous ~= tab
    and vim.api.nvim_tabpage_is_valid(previous)
  then
    local number = vim.api.nvim_tabpage_get_number(previous)
    pcall(function() vim.cmd(number .. 'tabclose') end)
  end
  fire(old, 'old')
  fire(new, 'new')
  return 'taken'
end

--- A diff tab opened. codediff announces it before it records the tab's
--- buffers (that waits for a side read from git), so ask again a little
--- later until it has them.
---@param data? { tabpage?: integer }
local function on_open(data)
  local path = current.want
  local tab = data and data.tabpage
  if not (path and tab) then return end
  local waited = 0
  local function try()
    if current.want ~= path or not vim.api.nvim_tabpage_is_valid(tab) then
      return
    end
    if claim(tab, path) ~= 'wait' then return end
    waited = waited + M.CLAIM_INTERVAL
    if waited > M.CLAIM_TIMEOUT then
      return changed('a diff tab never recorded its buffers')
    end
    vim.defer_fn(try, M.CLAIM_INTERVAL)
  end
  try()
end

--- Set the autocmds once; codediff's events reach every diff tab
local function setup()
  local group = vim.api.nvim_create_augroup('dy_review_diff', { clear = true })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'CodeDiffOpen',
    callback = function(args) on_open(args.data) end,
  })
  -- A side read from git fills in after the tab opens
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'CodeDiffVirtualFileLoaded',
    callback = function(args)
      local bufnr = args.data and args.data.buf
      if not (bufnr and current.tab) then return end
      if bufnr == current.old then fire(bufnr, 'old') end
      if bufnr == current.new then fire(bufnr, 'new') end
    end,
  })
  vim.api.nvim_create_autocmd('User', {
    group = group,
    pattern = 'CodeDiffClose',
    callback = function(args)
      if args.data and args.data.tabpage == current.tab then current = {} end
    end,
  })
end

--- Run `:CodeDiff file` with `revs` from buffer `bufnr`
---@param bufnr integer
---@param revs string[]
---@return boolean ok
---@return string? err
local function run(bufnr, revs)
  return pcall(
    vim.api.nvim_buf_call,
    bufnr,
    function()
      vim.cmd({ cmd = 'CodeDiff', args = vim.list_extend({ 'file' }, revs) })
    end
  )
end

--- Call `fn` for every side of a review's diff once its buffer is there, and
--- again when it fills in; one handler, the last one given
---@param fn fun(bufnr: integer, path: string, side: DyReviewSide)
function M.on_buffer(fn) handler = fn end

--- Show the change of `path`, merge-base to head, in a codediff tab
---@param session DyReviewSession
---@param path string
---@return 'opened'|'shown'|false # `shown` when that diff is open already
function M.open(session, path)
  if vim.fn.exists(':CodeDiff') ~= 2 then
    notify(
      'codediff.nvim is not installed: `:DyReview` needs it',
      vim.log.levels.ERROR
    )
    return false
  end
  if
    current.path == path
    and current.tab
    and vim.api.nvim_tabpage_is_valid(current.tab)
  then
    vim.api.nvim_set_current_tabpage(current.tab)
    return 'shown'
  end
  if vim.fn.exists('#dy_review_diff') == 0 then setup() end
  local full = vim.fs.joinpath(session.worktree, path)
  local bufnr = vim.fn.bufadd(full)
  vim.bo[bufnr].buflisted = true
  vim.fn.bufload(bufnr)
  current.want = path
  -- A file the pull request deletes is not in the worktree: both sides
  -- come from git
  local revs = vim.uv.fs_stat(full) and { session.merge_base }
    or { session.merge_base, session.pull.head_sha }
  if #revs == 1 and not lifecycle() then
    revs = { session.merge_base, session.pull.head_sha }
  end
  local ok, err = run(bufnr, revs)
  if not ok and #revs == 1 then
    changed('`:CodeDiff file <rev>` failed: ' .. tostring(err))
    revs = { session.merge_base, session.pull.head_sha }
    ok, err = run(bufnr, revs)
  end
  if not ok then
    current.want = nil
    notify(
      'Could not open the diff of ' .. path .. ': ' .. tostring(err),
      vim.log.levels.ERROR
    )
    return false
  end
  return 'opened'
end

--- The file and side buffer `bufnr` shows in the review's diff
---@param bufnr integer
---@return string? path
---@return DyReviewSide? side
function M.locate(bufnr)
  if not current.tab then return nil end
  if bufnr == current.new then return current.path, 'new' end
  if bufnr == current.old then return current.path, 'old' end
  return nil
end

--- The window showing `side` of the review's diff
---@param side DyReviewSide
---@return integer?
function M.window(side)
  if not (current.tab and vim.api.nvim_tabpage_is_valid(current.tab)) then
    return nil
  end
  local module = lifecycle()
  if not module then return nil end
  local ok, old, new = pcall(module.get_windows, current.tab)
  if not ok then
    changed('get_windows failed: ' .. tostring(old))
    return nil
  end
  local win = side == 'old' and old or new
  return (win and vim.api.nvim_win_is_valid(win)) and win or nil
end

--- Hand both sides to the handler again, after drafts or threads changed
function M.redraw()
  if not current.tab then return end
  fire(current.old, 'old')
  fire(current.new, 'new')
end

--- Close the review's diff tab
function M.close()
  local tab = current.tab
  current = {}
  if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then return end
  if #vim.api.nvim_list_tabpages() == 1 then vim.cmd('tabnew') end
  local number = vim.api.nvim_tabpage_get_number(tab)
  pcall(function() vim.cmd(number .. 'tabclose') end)
end

return M
