local h = require('helpers')

describe('plugins.lang.make', function()
  before_each(function() h.globals() end)

  it('reads every Makefile as GNU make, with no plugin of its own', function()
    assert.same({}, dofile(h.root .. '/lua/plugins/lang/make.lua'))
    assert.are.equal('gnu', vim.g.make_flavor)
  end)
end)
