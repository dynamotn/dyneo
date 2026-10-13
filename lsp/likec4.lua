-- nvim-lspconfig has no LikeC4 server: the standalone one of `@likec4/lsp`

---@type vim.lsp.Config
return {
  cmd = { 'likec4-lsp', '--stdio' },
  filetypes = { 'likec4' },
  -- A workspace is every model file under its root, read together. The
  -- server starts there only once the root is trusted to run the code
  -- config it holds, if any.
  root_dir = function(bufnr, on_dir)
    local c4 = require('tools.c4')
    local name = vim.api.nvim_buf_get_name(bufnr)
    local root = vim.fs.root(bufnr, c4.ROOT_MARKERS)
      or (name ~= '' and vim.fs.dirname(name))
    if not root then return end
    if c4.trusted('likec4', root, 'Start the LikeC4 server', true) then
      on_dir(root)
    end
  end,
}
