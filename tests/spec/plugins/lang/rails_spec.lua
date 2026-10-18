local h = require('helpers')

describe('plugins.lang.rails', function()
  before_each(function() h.globals() end)

  it('extends Ruby with the Rails snippets', function()
    local extended
    local restore = h.stub(package.loaded, 'luasnip', {
      filetype_extend = function(ft, with) extended = { ft, with } end,
    })
    local specs = dofile(h.root .. '/lua/plugins/lang/rails.lua')
    assert.are.equal('L3MON4D3/LuaSnip', specs[1][1])
    specs[1].opts()
    restore()
    assert.same({ 'ruby', { 'rails' } }, extended)
  end)
end)
