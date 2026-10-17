-- `:DyKube`: explain, diff, validate, apply and render the manifest,
-- kustomization or Helm chart being edited. The module only loads when asked,
-- or when a YAML buffer opens that holds a manifest, a kustomization or a
-- file of a Helm chart.
vim.api.nvim_create_user_command(
  'DyKube',
  function(args) require('tools.kube').command(args) end,
  {
    nargs = '?',
    complete = function(lead)
      local names = vim.tbl_keys(require('tools.kube').SUBCOMMANDS)
      table.sort(names)
      return vim.tbl_filter(
        function(name) return name:find(lead, 1, true) == 1 end,
        names
      )
    end,
    desc = 'Explain, diff, validate, apply or render this manifest',
  }
)

-- A copy of `tools.kube.is_kube`, so a YAML buffer that holds nothing for a
-- cluster never loads the module; its spec keeps the two equal
local HEAD_LINES = 200

--- Whether `bufnr` may hold something a cluster would take
---@param bufnr integer
---@return boolean
local function is_kube(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then return false end
  if vim.fs.basename(file):match('^[Kk]ustomization%.ya?ml$') then
    return true
  end
  local api, kind = false, false
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, HEAD_LINES, false)) do
    api = api or line:match('^apiVersion:') ~= nil
    kind = kind or line:match('^kind:') ~= nil
    if api and kind then return true end
  end
  return vim.fs.root(file, 'Chart.yaml') ~= nil
end

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_kube', { clear = true }),
  pattern = { 'yaml', 'yaml.*', 'helm' },
  callback = function(args)
    if is_kube(args.buf) then require('tools.kube').attach(args.buf) end
  end,
})
