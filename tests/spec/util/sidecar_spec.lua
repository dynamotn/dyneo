local h = require('helpers')

describe('util.sidecar', function()
  local sidecar

  before_each(function()
    h.unload('util.sidecar')
    sidecar = require('util.sidecar')
  end)

  it('keeps a server to the providers it is there for', function()
    local config = sidecar.only({ 'codeActionProvider', 'renameProvider' })
    local client = {
      server_capabilities = {
        textDocumentSync = 2,
        positionEncoding = 'utf-16',
        executeCommandProvider = { commands = { 'x' } },
        codeActionProvider = true,
        renameProvider = true,
        hoverProvider = true,
        completionProvider = {},
      },
    }
    config.on_init(client)
    assert.same({
      textDocumentSync = 2,
      positionEncoding = 'utf-16',
      executeCommandProvider = { commands = { 'x' } },
      codeActionProvider = true,
      renameProvider = true,
    }, client.server_capabilities)
  end)

  it('throws its diagnostics away', function()
    local shown = false
    local restore = h.stub(vim.diagnostic, 'set', function() shown = true end)
    sidecar.only({}).handlers['textDocument/publishDiagnostics'](nil, {
      uri = 'file:///p/a',
      diagnostics = { { message = 'x', range = {} } },
    }, { client_id = 1 })
    restore()
    assert.is_false(shown)
  end)
end)
