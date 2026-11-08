local h = require('helpers')

describe('lsp.pylsp', function()
  local config

  before_each(function() config = dofile(h.root .. '/lsp/pylsp.lua') end)

  it('keeps only the rope refactorings, beside pyright', function()
    local client = {
      server_capabilities = {
        textDocumentSync = 2,
        codeActionProvider = true,
        executeCommandProvider = { commands = { 'pylsp_rope.refactor' } },
        renameProvider = true,
        completionProvider = {},
        hoverProvider = true,
      },
    }
    config.on_init(client)
    assert.same({
      textDocumentSync = 2,
      codeActionProvider = true,
      executeCommandProvider = { commands = { 'pylsp_rope.refactor' } },
    }, client.server_capabilities)
  end)

  it('runs none of its linters or formatters', function()
    local plugins = config.settings.pylsp.plugins
    for _, name in ipairs({
      'pycodestyle',
      'pyflakes',
      'pylint',
      'mccabe',
      'flake8',
      'autopep8',
      'yapf',
      'pydocstyle',
    }) do
      assert.is_false(plugins[name].enabled, name)
    end
  end)
end)
