local h = require('helpers')

describe('plugins.coding.indent: nvim-parinfer', function()
  it('loads for the Lisp family only', function()
    local spec = dofile(h.root .. '/lua/plugins/coding/indent.lua')[1]
    assert.equals('gpanders/nvim-parinfer', spec[1])
    assert.is_true(vim.list_contains(spec.ft, 'clojure'))
    assert.is_true(vim.list_contains(spec.ft, 'fennel'))
    assert.is_false(vim.list_contains(spec.ft, 'lua'))
  end)
end)
