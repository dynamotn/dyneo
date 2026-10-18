local h = require('helpers')

describe('plugins.toolbox.regex', function()
  before_each(function() h.globals() end)

  it('loads the explainer on the first idle moment, not with a file', function()
    local specs = dofile(h.root .. '/lua/plugins/toolbox/regex.lua')
    assert.are.equal(1, #specs)
    local regexplainer = specs[1]
    assert.are.equal('bennypowers/nvim-regexplainer', regexplainer[1])
    assert.are.equal('CursorHold', regexplainer.event)
    assert.is_true(regexplainer.opts.auto)
    assert.are.equal('<leader>uR', regexplainer.keys[1][1])
    assert.are.equal('<cmd>RegexplainerToggle<cr>', regexplainer.keys[1][2])
  end)
end)
