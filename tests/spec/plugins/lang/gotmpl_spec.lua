local h = require('helpers')

describe('plugins.lang.gotmpl', function()
  before_each(function() h.globals() end)

  it('comments a template with a trimmed action', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/gotmpl.lua')
    assert.are.equal('nvim-mini/mini.icons', specs[1][1])
    assert.are.equal('MiniIconsGrey', specs[1].opts.filetype.gotmpl.hl)
    assert.same({ '{{- /* %s */ }}' }, specs[2].opts.lang.gotmpl)
  end)
end)
