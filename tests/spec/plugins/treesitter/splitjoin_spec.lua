local h = require('helpers')

describe('plugins.treesitter.splitjoin', function()
  before_each(function() h.globals() end)

  it('splits or joins the block under the cursor with gS', function()
    local toggled = 0
    local restore = h.stub(package.loaded, 'treesj', {
      toggle = function() toggled = toggled + 1 end,
    })
    local spec = dofile(h.root .. '/lua/plugins/treesitter/splitjoin.lua')[1]
    assert.equals('gS', spec.keys[1][1])
    spec.keys[1][2]()
    restore()
    assert.equals(1, toggled)
    assert.is_false(spec.opts.use_default_keymaps)
  end)
end)
