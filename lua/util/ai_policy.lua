--- Projects whose code may only go to an AI running on this machine
---
--- A client's repository, or one under an agreement that keeps its code off
--- third-party services, says so with a `.nvim/ai.json` of
--- `{ "local_only": true }`, or is named in `DyNeo.ai.local_only` on a
--- machine. Inside one, every AI integration that sends text away is refused:
--- Copilot does not attach, Claude Code and the CLIs of sidekick are handed
--- nothing, and Avante and `:DyAi` only speak to a provider of
--- `DyNeo.ai.local_providers`.
---
--- The file is read without asking for trust: it can only take sending
--- away, never allow it, so a repository gains nothing by writing one.
local M = {}

--- The file a project keeps AI local with, relative to its root
M.FILE = '.nvim/ai.json'

--- Milliseconds an answer about a folder is kept: the statusline and Claude
--- Code's selection ask on every redraw and cursor move
M.TTL = 5000

---@type table<string, { at: integer, reason: string|false }>
local cache = {}

--- The resolved folder of each path asked about, kept as long as an answer:
--- resolving it is two system calls, too many for every redraw
---@type table<string, { at: integer, dir: string }>
local dirs = {}

--- Drop what is known about every folder, for the specs
function M.reset()
  cache, dirs = {}, {}
end

---@param path string
---@return string
local function resolve(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- Whether `path` is `dir` or inside it, with the separator compared too
---@param dir string
---@param path string
---@return boolean
local function inside(dir, path)
  return path == dir or vim.startswith(path, dir:gsub('/$', '') .. '/')
end

--- Why the folder `dir` keeps AI local, or false
---@param dir string Resolved
---@return string|false
local function lookup(dir)
  for _, root in ipairs((DyNeo.ai or {}).local_only or {}) do
    if inside(resolve(root), dir) then
      return ('DyNeo.ai.local_only names %s'):format(
        vim.fn.fnamemodify(root, ':~')
      )
    end
  end
  for parent in vim.fs.parents(dir .. '/x') do
    local file = parent .. '/' .. M.FILE
    if vim.uv.fs_stat(file) then
      local ok, lines = pcall(vim.fn.readfile, file)
      local decoded, data =
        pcall(vim.json.decode, ok and table.concat(lines, '\n') or '')
      -- A file that does not read is taken at its word all the same: it is
      -- only ever written to keep AI local
      if not decoded or type(data) ~= 'table' or data.local_only ~= false then
        return ('%s keeps AI local'):format(vim.fn.fnamemodify(file, ':~'))
      end
      return false
    end
  end
  return false
end

--- Why AI must stay local for `target`, or nil when it need not
---@param target? integer|string A buffer, or a path; the current buffer
--- unless given
---@return string? reason
function M.local_only(target)
  local path
  if type(target) == 'string' then
    path = target
  else
    local bufnr = (target == nil or target == 0)
        and vim.api.nvim_get_current_buf()
      or target --[[@as integer]]
    path = vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_get_name(bufnr)
      or ''
  end
  if path == '' or path:match('^%a[%w+.-]*://') then
    path = vim.uv.cwd() or '.'
  end
  local now = vim.uv.now()
  local seen = dirs[path]
  if not seen or now - seen.at > M.TTL then
    local resolved = resolve(path)
    local stat = vim.uv.fs_stat(resolved)
    seen = {
      at = now,
      dir = (stat and stat.type == 'directory') and resolved
        or vim.fs.dirname(resolved),
    }
    dirs[path] = seen
  end
  local dir = seen.dir
  local known = cache[dir]
  if not known or now - known.at > M.TTL then
    known = { at = now, reason = lookup(dir) }
    cache[dir] = known
  end
  return known.reason or nil
end

--- Whether Avante's provider `name` runs on this machine
---@param name? string Avante's current provider unless given
---@return boolean
function M.is_local_provider(name)
  if not name then
    local config = package.loaded['avante.config']
    name = config and config.provider
  end
  return name ~= nil
    and vim.list_contains((DyNeo.ai or {}).local_providers or {}, name)
end

--- The command writing text from a prompt in the project of `target`: the
--- local one where AI stays local, nil when none is set there
---@param target? integer|string
---@return string[]? command
---@return string? reason Why there is none
function M.command(target)
  local ai = DyNeo.ai or {}
  local reason = M.local_only(target)
  if not reason then return ai.commit_command or { 'claude', '-p' } end
  if ai.local_command then return ai.local_command end
  return nil, reason .. ', and DyNeo.ai.local_command is not set'
end

return M
