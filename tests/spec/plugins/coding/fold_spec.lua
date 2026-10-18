local h = require('helpers')

describe('plugins.coding.fold: nvim-origami', function()
  it('leaves the LSP folds and the auto fold off', function()
    local spec = dofile(h.root .. '/lua/plugins/coding/fold.lua')[1]
    assert.equals('chrisgrieser/nvim-origami', spec[1])
    assert.is_false(spec.opts.useLspFoldsWithTreesitterFallback.enabled)
    assert.is_false(spec.opts.autoFold.enabled)
  end)
end)
