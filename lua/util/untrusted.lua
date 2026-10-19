--- Directories whose code nothing may run until the user trusts them
---
--- A review checks the author's code out into a worktree, and language
--- servers and a project's `.nvim` folder would run that code the moment a
--- buffer there opens. A held directory keeps both off: servers' `root_dir`
--- and `util.project_rtp` ask `held` first, and `release` starts the servers
--- once the user says yes. This is asked for every buffer and every server,
--- so with nothing held it costs one table check.
local M = {}

--- The augroup `vim.lsp.enable` starts servers from, on nightly and 0.12
M.LSP_GROUP = 'nvim.lsp.enable'

---@class DyUntrustedHold
---@field on_first? fun(bufnr: integer)
---@field asked boolean Whether `on_first` has been scheduled

---@type table<string, DyUntrustedHold> By real path, without a trailing `/`
local holds = {}

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
  holds[resolve(dir)] = { on_first = on_first, asked = false }
end

--- Let `dir` go without starting anything
---@param dir string
function M.forget(dir) holds[resolve(dir)] = nil end

--- Let `dir` go and start the servers of its loaded buffers. Only the
--- `vim.lsp.enable` group runs again, so ftplugins do not.
---@param dir string
function M.release(dir)
  dir = resolve(dir)
  holds[dir] = nil
  local ok, autocmds = pcall(vim.api.nvim_get_autocmds, {
    group = M.LSP_GROUP,
    event = 'FileType',
  })
  -- No group: no server is enabled, so there is nothing to start
  if not ok or #autocmds == 0 then return end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and name ~= ''
      and not M.held(bufnr)
      and under(dir, resolve(name))
    then
      vim.api.nvim_exec_autocmds(
        'FileType',
        { group = M.LSP_GROUP, buffer = bufnr }
      )
    end
  end
end

--- Whether the buffer or path lies under a held directory. The first `true`
--- of a hold schedules its `on_first`.
---@param target integer|string A buffer, `0` for the current one, or a path
---@return boolean
function M.held(target)
  if next(holds) == nil then return false end
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
  path = resolve(path)
  for dir, hold in pairs(holds) do
    if under(dir, path) then
      if hold.on_first and not hold.asked then
        hold.asked = true
        local first = bufnr or vim.api.nvim_get_current_buf()
        vim.schedule(function() hold.on_first(first) end)
      end
      return true
    end
  end
  return false
end

return M
