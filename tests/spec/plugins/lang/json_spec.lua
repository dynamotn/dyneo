local h = require('helpers')

describe('plugins.lang.json', function()
  local restores

  before_each(function()
    h.globals()
    restores = {
      h.stub(package.loaded, 'codesettings', {
        with_local_settings = function(_, config)
          config.settings.json.schemas = {
            { fileMatch = { 'config.json' }, url = './schema.json' },
          }
        end,
      }),
      h.stub(package.loaded, 'schemastore', {
        json = {
          schemas = function()
            return { { fileMatch = { 'package.json' }, url = 'store' } }
          end,
        },
      }),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it("keeps the project's own schemas next to SchemaStore's", function()
    local jsonls
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/json.lua')) do
      if spec[1] == 'neovim/nvim-lspconfig' then
        jsonls = spec.opts.servers.jsonls
      end
    end
    local config = { name = 'jsonls', settings = { json = {} } }
    jsonls.before_init(nil, config)
    assert.same({
      { fileMatch = { 'config.json' }, url = './schema.json' },
      { fileMatch = { 'package.json' }, url = 'store' },
    }, config.settings.json.schemas)
  end)

  it('retries the schemas the server failed to fetch', function()
    local client
    table.insert(
      restores,
      h.stub(require('util.json_schema'), 'on_init', function(c) client = c end)
    )
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/json.lua')) do
      if spec[1] == 'neovim/nvim-lspconfig' then
        spec.opts.servers.jsonls.on_init('jsonls client')
      end
    end
    assert.are.equal('jsonls client', client)
  end)
end)
