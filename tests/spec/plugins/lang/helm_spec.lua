local h = require('helpers')

describe('plugins.lang.helm', function()
  before_each(function() h.globals() end)

  it('gives Helm templates an icon of their own', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/helm.lua')
    assert.are.equal(1, #specs)
    assert.are.equal('nvim-mini/mini.icons', specs[1][1])
    assert.are.equal('MiniIconsGrey', specs[1].opts.filetype.helm.hl)
  end)
end)
