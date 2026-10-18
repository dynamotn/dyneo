local h = require('helpers')

describe('plugins.coding.document: neogen', function()
  local spec, restores, calls

  before_each(function()
    calls = {}
    restores = {
      h.stub(package.loaded, 'neogen', {
        setup = function(opts) table.insert(calls, { 'setup', opts }) end,
        generate = function() table.insert(calls, { 'generate' }) end,
      }),
      h.stub(package.loaded, 'util.neogen', {
        languages = function() return { sh = 'built', lua = 'built' } end,
        install_arg_sentinel_fixup = function()
          table.insert(calls, { 'fixup' })
        end,
      }),
    }
    spec = dofile(h.root .. '/lua/plugins/coding/document.lua')[1]
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('expands through LuaSnip, with the languages built here', function()
    local opts = { languages = { lua = 'given' } }
    spec.opts(nil, opts)
    assert.equals('luasnip', opts.snippet_engine)
    assert.same({ sh = 'built', lua = 'given' }, opts.languages)
    spec.opts(nil, {})
  end)

  it('sets neogen up, then fixes its shell arguments', function()
    local opts = {}
    spec.config(nil, opts)
    spec.keys[1][2]()
    assert.same({ { 'setup', opts }, { 'fixup' }, { 'generate' } }, calls)
  end)
end)
