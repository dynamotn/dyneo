-- nvim-lspconfig starts yls with `-vv`, which writes every request it
-- handles to the LSP log
---@type vim.lsp.Config
return {
  cmd = { 'yls' },
}
