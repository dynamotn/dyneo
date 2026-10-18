local h = require('helpers')

describe('plugins.lang.terragrunt', function()
  before_each(function() h.globals() end)

  it('drops the diagnostics of terragruntls', function()
    local hook
    local restore = h.stub(_G, 'Snacks', {
      util = {
        lsp = {
          on = function(filter, fn)
            assert.are.equal('terragruntls', filter.name)
            hook = fn
          end,
        },
      },
    })
    local specs = dofile(h.root .. '/lua/plugins/lang/terragrunt.lua')
    specs[1].opts.setup.terragruntls()
    restore()
    local published = false
    local client = {
      handlers = {
        ['textDocument/publishDiagnostics'] = function() published = true end,
      },
    }
    hook(nil, client)
    client.handlers['textDocument/publishDiagnostics']()
    assert.is_false(published)
  end)
end)
