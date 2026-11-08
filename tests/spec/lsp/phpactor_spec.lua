local h = require('helpers')

describe('lsp.phpactor', function()
  local config

  before_each(function() config = dofile(h.root .. '/lsp/phpactor.lua') end)

  it('keeps only its refactorings, beside intelephense', function()
    local client = {
      server_capabilities = {
        textDocumentSync = 2,
        positionEncoding = 'utf-16',
        codeActionProvider = true,
        renameProvider = true,
        executeCommandProvider = { commands = { 'import_class' } },
        completionProvider = {},
        hoverProvider = true,
        definitionProvider = true,
        referencesProvider = true,
        documentFormattingProvider = true,
        inlayHintProvider = true,
      },
    }
    config.on_init(client)
    assert.same({
      textDocumentSync = 2,
      positionEncoding = 'utf-16',
      codeActionProvider = true,
      renameProvider = true,
      executeCommandProvider = { commands = { 'import_class' } },
    }, client.server_capabilities)
  end)

  it('leaves the diagnostics to intelephense', function()
    local shown = false
    local restore = h.stub(vim.diagnostic, 'set', function() shown = true end)
    config.handlers['textDocument/publishDiagnostics'](nil, {
      uri = 'file:///p/a.php',
      diagnostics = { { message = 'x', range = {} } },
    }, { client_id = 1 })
    restore()
    assert.is_false(shown)
  end)
end)
