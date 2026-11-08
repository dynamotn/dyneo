-- phpactor runs beside intelephense for what its free tier lacks: rename and
-- the refactoring code actions (extract, import, generate). Everything else
-- intelephense answers, so phpactor's other providers are dropped, and its
-- diagnostics too, which no capability turns off.

--- What phpactor keeps of its capabilities
local KEEP = {
  textDocumentSync = true,
  positionEncoding = true,
  codeActionProvider = true,
  renameProvider = true,
  -- Its code actions run as commands
  executeCommandProvider = true,
}

---@type vim.lsp.Config
return {
  on_init = function(client)
    for name in pairs(client.server_capabilities) do
      if not KEEP[name] then client.server_capabilities[name] = nil end
    end
  end,
  handlers = {
    ['textDocument/publishDiagnostics'] = function() end,
  },
}
