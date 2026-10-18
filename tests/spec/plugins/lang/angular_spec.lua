local h = require('helpers')

describe('plugins.lang.angular', function()
  local restores, specs

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/lang/angular.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it(
    'extends the templates and the TypeScript with Angular snippets',
    function()
      local extended = {}
      table.insert(
        restores,
        h.stub(package.loaded, 'luasnip', {
          filetype_extend = function(ft, with) extended[ft] = with end,
        })
      )
      specs[1].opts()
      assert.are.equal('L3MON4D3/LuaSnip', specs[1][1])
      assert.same(
        { htmlangular = { 'angular' }, typescript = { 'angular' } },
        extended
      )
    end
  )

  it('leaves renaming to the TypeScript server', function()
    local hook
    table.insert(
      restores,
      h.stub(_G, 'Snacks', {
        util = {
          lsp = {
            on = function(filter, fn)
              assert.are.equal('angularls', filter.name)
              hook = fn
            end,
          },
        },
      })
    )
    specs[2].opts.setup.angularls()
    local client = { server_capabilities = { renameProvider = true } }
    hook(nil, client)
    assert.is_false(client.server_capabilities.renameProvider)
  end)
end)
