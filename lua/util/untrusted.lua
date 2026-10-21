--- Directories whose code nothing may run until the user trusts them
---
--- A review checks the author's code out into a worktree, and language
--- servers and a project's `.nvim` folder would run that code the moment a
--- buffer there opens. A held directory keeps both off: servers' `root_dir`
--- and `util.project_rtp` ask `held` first, and `release` starts the servers
--- once the user says yes. This is asked for every buffer and every server,
--- so with nothing held it costs one table check, and a pattern hold one
--- string match per name.
local M = {}

--- The augroup `vim.lsp.enable` starts servers from, on nightly and 0.12
M.LSP_GROUP = 'nvim.lsp.enable'

---@class DyUntrustedHold
---@field on_first? fun(bufnr: integer)
---@field asked boolean Whether `on_first` has been scheduled

---@type table<string, DyUntrustedHold> By real path, without a trailing `/`
local holds = {}

--- Lua patterns whose first capture is a directory held by its name alone,
--- from before any session holds it exactly
---@type table<string, true>
local patterns = {}

--- Directories a pattern names that were let go once trusted, by real path
---@type table<string, true>
local released = {}

--- `path` normalized and resolved, a file not there yet by its directory
---@param path string
---@return string
local function resolve(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local real = vim.uv.fs_realpath(path)
  if not real then
    local parent = vim.uv.fs_realpath(vim.fs.dirname(path))
    real = parent and vim.fs.joinpath(parent, vim.fs.basename(path)) or path
  end
  real = vim.fs.normalize(real)
  return #real > 1 and real:gsub('/$', '') or real
end

--- Whether `path`, resolved, is `dir` or lies under it
---@param dir string
---@param path string
---@return boolean
local function under(dir, path)
  if path == dir then return true end
  local prefix = dir == '/' and dir or dir .. '/'
  return path:sub(1, #prefix) == prefix
end

--- Hold servers and `.nvim` off every buffer under `dir`
---@param dir string
---@param on_first? fun(bufnr: integer) Run once, scheduled, for the first
--- held buffer something asks about
function M.hold(dir, on_first)
  dir = resolve(dir)
  holds[dir] = { on_first = on_first, asked = false }
  released[dir] = nil
end

--- Hold every directory `pattern` names, matched against the absolute name
--- of a buffer or path as given: a worktree an earlier session left, or
--- one a crash left behind, is held from startup without knowing it. Only a
--- `release` after trust lets one of them go.
---@param pattern string A Lua pattern whose first capture is the directory
function M.hold_pattern(pattern) patterns[pattern] = true end

--- Let `dir` go without starting anything; a directory a pattern names is
--- held by it again
---@param dir string
function M.forget(dir)
  dir = resolve(dir)
  holds[dir] = nil
  released[dir] = nil
end

---@type table<string, fun(bufnr: integer)> By the name they were given
local starters = {}

--- Start, for a buffer let go, a server its own plugin starts outside
--- `vim.lsp.enable` (rustaceanvim, nvim-jdtls, ...), which re-running the
--- `vim.lsp.enable` group does not reach. Kept by name, so loading the
--- plugin's spec again replaces its starter instead of adding a second one.
---@param name string
---@param start fun(bufnr: integer) Called for every buffer let go; it checks
--- the filetype itself
function M.on_release(name, start) starters[name] = start end

--- Let `dir` go and start the servers of its loaded buffers: the
--- `vim.lsp.enable` group runs again (alone, so ftplugins do not), then the
--- starters of `on_release`.
---@param dir string
function M.release(dir)
  dir = resolve(dir)
  holds[dir] = nil
  released[dir] = true
  local buffers = {} ---@type integer[]
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and name ~= ''
      and not M.held(bufnr)
      and under(dir, resolve(name))
    then
      table.insert(buffers, bufnr)
    end
  end
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
    group = M.LSP_GROUP,
    event = 'FileType',
  })
  -- No group: `vim.lsp.enable` has no server to start
  local enabled = ok and #autocmds > 0
  for _, bufnr in ipairs(buffers) do
    if enabled then
      vim.api.nvim_exec_autocmds(
        'FileType',
        { group = M.LSP_GROUP, buffer = bufnr }
      )
    end
    for name, start in vim.spairs(starters) do
      local started, err = pcall(start, bufnr)
      if not started then
        vim.notify(
          ('Could not start %s: %s'):format(name, err),
          vim.log.levels.ERROR,
          { title = require('util.notify').title('review') }
        )
      end
    end
  end
end

--- Whether the buffer or path lies under a held directory. The first `true`
--- of a hold schedules its `on_first`.
---@param target integer|string A buffer, `0` for the current one, or a path
---@return boolean
function M.held(target)
  if next(holds) == nil and next(patterns) == nil then return false end
  local bufnr ---@type integer?
  local path ---@type string
  if type(target) == 'number' then
    bufnr = target == 0 and vim.api.nvim_get_current_buf() or target
    path = vim.api.nvim_buf_get_name(bufnr)
    -- An unnamed or non-file buffer (`oil://`, `term://`) lives nowhere
    if path == '' or path:match('^%a[%w+.-]*://') then return false end
  else
    path = target --[[@as string]]
  end
  -- An exact hold first: its `on_first` asks the trust question
  if next(holds) ~= nil then
    local real = resolve(path)
    for dir, hold in pairs(holds) do
      if under(dir, real) then
        if hold.on_first and not hold.asked then
          hold.asked = true
          local first = bufnr or vim.api.nvim_get_current_buf()
          vim.schedule(function() hold.on_first(first) end)
        end
        return true
      end
    end
  end
  if next(patterns) == nil then return false end
  local name = path:sub(1, 1) == '/' and path or vim.fn.fnamemodify(path, ':p')
  name = vim.fs.normalize(name)
  for pattern in pairs(patterns) do
    local dir = name:match(pattern)
    if dir and not released[resolve(dir)] then return true end
  end
  return false
end

return M
