local Plugin = require('util.plugin')

--- Project root of a buffer, from its LSP clients, then root markers, then
--- the working directory. `require('util.root')()` is `get()`.
---@class util.root
---@overload fun(opts?: { normalize?: boolean, buf?: number }): string
local M = setmetatable({}, {
  __call = function(m, ...) return m.get(...) end,
})

---@alias RootFn fun(buf: number): (string|string[])
---@alias RootSpec string|string[]|RootFn

--- Detectors in order; `vim.g.root_spec` takes over when set
---@type RootSpec[]
M.spec = { 'lsp', { '.git', 'lua' }, 'cwd' }

M.detectors = {}

function M.detectors.cwd() return { vim.uv.cwd() } end

--- Whether `path` is `dir` or lies under it: `/x/proj` holds `/x/proj/f`
--- but not `/x/proj-other/f`
---@param dir string
---@param path string
---@return boolean
function M.contains(dir, path)
  if path == dir then return true end
  local prefix = dir:sub(-1) == '/' and dir or dir .. '/'
  return path:sub(1, #prefix) == prefix
end

function M.detectors.lsp(buf)
  local bufpath = M.bufpath(buf)
  if not bufpath then return {} end
  local roots = {} ---@type string[]
  local clients = vim.tbl_filter(
    function(client)
      return not vim.tbl_contains(vim.g.root_lsp_ignore or {}, client.name)
    end,
    vim.lsp.get_clients({ bufnr = buf })
  ) --[[@as vim.lsp.Client[] ]]
  for _, client in pairs(clients) do
    -- The client's own list takes in the folders added since it started
    local folders = client.workspace_folders
      or client.config.workspace_folders
      or {}
    for _, ws in pairs(folders) do
      roots[#roots + 1] = vim.uri_to_fname(ws.uri)
    end
    if client.root_dir then roots[#roots + 1] = client.root_dir end
  end
  -- Resolved like `bufpath`: a root reached through a symlink (a chezmoi
  -- `mode: symlink` home) still holds the file it links to
  return vim.tbl_filter(function(path)
    path = M.realpath(path) or Plugin.norm(path)
    return path and M.contains(path, bufpath)
  end, roots)
end

---@param patterns string[]|string
function M.detectors.pattern(buf, patterns)
  patterns = type(patterns) == 'string' and { patterns } or patterns
  local path = M.bufpath(buf) or vim.uv.cwd()
  local pattern = vim.fs.find(function(name)
    for _, p in ipairs(patterns) do
      if name == p then return true end
      if p:sub(1, 1) == '*' and name:find(vim.pesc(p:sub(2)) .. '$') then
        return true
      end
    end
    return false
  end, { path = path, upward = true })[1]
  return pattern and { vim.fs.dirname(pattern) } or {}
end

function M.bufpath(buf) return M.realpath(vim.api.nvim_buf_get_name(buf)) end

--- The working directory as `getcwd` gave it, and resolved
local cwd_seen, cwd_resolved

--- The working directory, symlinks resolved
---
--- Asked on every statusline redraw: resolving walks each component of the
--- path, so it is done again only once the directory itself changes.
---@return string
function M.cwd()
  local cwd = vim.uv.cwd()
  if cwd ~= cwd_seen then
    cwd_seen, cwd_resolved = cwd, M.realpath(cwd) or ''
  end
  return cwd_resolved
end

function M.realpath(path)
  if path == '' or path == nil then return nil end
  path = vim.fn.has('win32') == 0 and vim.uv.fs_realpath(path) or path
  return Plugin.norm(path)
end

---@param spec RootSpec
---@return RootFn
function M.resolve(spec)
  if M.detectors[spec] then
    return M.detectors[spec]
  elseif type(spec) == 'function' then
    return spec
  end
  return function(buf) return M.detectors.pattern(buf, spec) end
end

---@param opts? { buf?: number, spec?: RootSpec[], all?: boolean }
---@return { spec: RootSpec, paths: string[] }[]
function M.detect(opts)
  opts = opts or {}
  opts.spec = opts.spec
    or type(vim.g.root_spec) == 'table' and vim.g.root_spec
    or M.spec
  opts.buf = (opts.buf == nil or opts.buf == 0)
      and vim.api.nvim_get_current_buf()
    or opts.buf

  local ret = {}
  for _, spec in ipairs(opts.spec) do
    local paths = M.resolve(spec)(opts.buf) or {}
    paths = type(paths) == 'table' and paths or { paths }
    local roots = {} ---@type string[]
    for _, p in ipairs(paths) do
      local pp = M.realpath(p)
      if pp and not vim.tbl_contains(roots, pp) then roots[#roots + 1] = pp end
    end
    table.sort(roots, function(a, b) return #a > #b end)
    if #roots > 0 then
      ret[#ret + 1] = { spec = spec, paths = roots }
      if opts.all == false then break end
    end
  end
  return ret
end

--- Show every root found for the current buffer, the chosen one first
---@return string
function M.info()
  local spec = type(vim.g.root_spec) == 'table' and vim.g.root_spec or M.spec
  local roots = M.detect({ all = true })
  local lines = {} ---@type string[]
  local first = true
  for _, root in ipairs(roots) do
    for _, path in ipairs(root.paths) do
      lines[#lines + 1] = ('- [%s] `%s` **(%s)**'):format(
        first and 'x' or ' ',
        path,
        type(root.spec) == 'table' and table.concat(root.spec, ', ')
          or root.spec
      )
      first = false
    end
  end
  lines[#lines + 1] = '```lua'
  lines[#lines + 1] = 'vim.g.root_spec = ' .. vim.inspect(spec)
  lines[#lines + 1] = '```'
  Plugin.info(lines, { title = 'DyNeo Roots' })
  return roots[1] and roots[1].paths[1] or vim.uv.cwd()
end

---@type table<number, string>
M.cache = {}

--- Add `:DyRoot`, and forget a buffer's root whenever it may have moved
function M.setup()
  -- Roots asked for while starting were worked out before any file was read
  M.cache = {}
  vim.api.nvim_create_user_command(
    'DyRoot',
    function() M.info() end,
    { desc = 'DyNeo roots for the current buffer' }
  )
  vim.api.nvim_create_autocmd({
    'LspAttach',
    'LspDetach',
    'BufWritePost',
    'BufFilePost',
    'DirChanged',
    'BufEnter',
    'BufWipeout',
  }, {
    group = vim.api.nvim_create_augroup('dyneo_root_cache', { clear = true }),
    callback = function(event) M.cache[event.buf] = nil end,
  })
end

--- Return the root of `opts.buf` (the current buffer by default)
---@param opts? { normalize?: boolean, buf?: number }
---@return string
function M.get(opts)
  opts = opts or {}
  -- `0` is cached under the real number, which the autocmds above clear
  local buf = (opts.buf == nil or opts.buf == 0)
      and vim.api.nvim_get_current_buf()
    or opts.buf
  local ret = M.cache[buf]
  if not ret then
    local roots = M.detect({ all = false, buf = buf })
    ret = roots[1] and roots[1].paths[1] or vim.uv.cwd()
    M.cache[buf] = ret
  end
  if opts.normalize then return ret end
  return vim.fn.has('win32') == 1 and ret:gsub('/', '\\') or ret
end

--- Return the git work tree around the root, or the root itself
---@return string
function M.git()
  local root = M.get()
  local git_root = vim.fs.find('.git', { path = root, upward = true })[1]
  return git_root and vim.fn.fnamemodify(git_root, ':h') or root
end

return M
