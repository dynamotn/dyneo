local h = require('helpers')

describe('plugins.lang.r', function()
  local restore

  before_each(function()
    h.globals()
    restore = h.stub(vim.g, 'R_filetypes', nil)
  end)
  after_each(function() restore() end)

  it('loads R.nvim on the filetypes it is told to serve', function()
    local spec
    for _, s in ipairs(dofile(h.root .. '/lua/plugins/lang/r.lua')) do
      if s[1] == 'R-nvim/R.nvim' then spec = s end
    end
    assert.is_not_false(spec.lazy)
    spec.init()
    assert.is_true(vim.list_contains(spec.ft, 'r'))
    assert.same(spec.ft, vim.g.R_filetypes)
  end)
end)
