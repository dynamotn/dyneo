--- A server that runs beside a language's main one for a few providers only
---
--- `lsp/<server>.lua` files require this, and they load outside lazy.nvim
--- too (`scripts/validate-tools.lua`), so it requires nothing.
local M = {}

--- Server config keeping `providers` of what the server offers and dropping
--- the rest; its diagnostics, which no capability turns off, are thrown away
---@param providers string[] Capability names to keep, besides text sync and
--- `executeCommandProvider`, which code actions run through
---@return vim.lsp.Config
function M.only(providers)
  local keep = {
    textDocumentSync = true,
    positionEncoding = true,
    executeCommandProvider = true,
  }
  for _, name in ipairs(providers) do
    keep[name] = true
  end
  return {
    on_init = function(client)
      for name in pairs(client.server_capabilities) do
        if not keep[name] then client.server_capabilities[name] = nil end
      end
    end,
    handlers = {
      ['textDocument/publishDiagnostics'] = function() end,
    },
  }
end

return M
