-- phpactor runs beside intelephense for what its free tier lacks: rename and
-- the refactoring code actions (extract, import, generate). Everything else
-- intelephense answers.
---@type vim.lsp.Config
return require('util.sidecar').only({ 'codeActionProvider', 'renameProvider' })
