-- nvim-lspconfig has no LikeC4 server: the standalone one of `@likec4/lsp`

-- The configs the server reads, as `@likec4/lsp` names them; it loads the
-- JavaScript and TypeScript ones by running them
local JSON_CONFIGS =
  { '.likec4rc', '.likec4.config.json', 'likec4.config.json' }
local CODE_CONFIGS = {
  'likec4.config.js',
  'likec4.config.cjs',
  'likec4.config.mjs',
  'likec4.config.ts',
  'likec4.config.cts',
  'likec4.config.mts',
}
local MARKERS = vim.list_extend(
  vim.list_extend(vim.deepcopy(JSON_CONFIGS), CODE_CONFIGS),
  { '.git' }
)

-- Entries walked under a root before it is taken to hold a code config:
-- an unread rest must not be a clean result
local SCAN_LIMIT = 20000

---@type table<string, string|false>
local code_config_of = {}

--- The first code config under `root` that the server would read, as it
--- walks: no hidden entry, no `node_modules` nor `out`. False when there is
--- none.
---@param root string
---@return string|false
local function code_config(root)
  if code_config_of[root] ~= nil then return code_config_of[root] end
  local found, seen = false, 0
  for name, kind in
    vim.fs.dir(root, {
      depth = math.huge,
      skip = function(dir)
        local base = vim.fs.basename(dir)
        return not vim.startswith(base, '.')
          and base ~= 'node_modules'
          and base ~= 'out'
      end,
    })
  do
    seen = seen + 1
    if seen > SCAN_LIMIT then
      found = 'any likec4.config.* among its files'
      break
    end
    if
      kind == 'file' and vim.list_contains(CODE_CONFIGS, vim.fs.basename(name))
    then
      found = name
      break
    end
  end
  code_config_of[root] = found
  return found
end

---@type vim.lsp.Config
return {
  cmd = { 'likec4-lsp', '--stdio' },
  filetypes = { 'likec4' },
  -- A workspace is every model file under its root, read together. The
  -- server starts there only once the root is trusted to run the code
  -- config it holds, if any.
  root_dir = function(bufnr, on_dir)
    local name = vim.api.nvim_buf_get_name(bufnr)
    local root = vim.fs.root(bufnr, MARKERS)
      or (name ~= '' and vim.fs.dirname(name))
    if not root then return end
    local config = code_config(root)
    if not config then return on_dir(root) end
    local question = ('Start the LikeC4 server in %s?\nIt runs %s as you.'):format(
      vim.fn.fnamemodify(root, ':~'),
      config
    )
    if require('util.trust').ask('likec4', root, question, true) then
      on_dir(root)
    end
  end,
}
