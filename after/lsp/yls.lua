-- nvim-lspconfig starts yls with `-vv`, which writes every request it
-- handles to the LSP log. Under `after/`, so this file is merged after the
-- plugin's own `lsp/yls.lua` and its `cmd` is the one that holds
---@type vim.lsp.Config
return {
  cmd = { 'yls' },
}
