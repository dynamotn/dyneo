local h = require('helpers')

describe('plugin/matrix', function()
  it('works out the matrix on :DyMatrix', function()
    local updated = 0
    local restore = h.stub(package.loaded, 'tools.matrix', {
      update = function() updated = updated + 1 end,
    })
    dofile(h.root .. '/plugin/matrix.lua')
    vim.cmd('DyMatrix')
    restore()
    vim.api.nvim_del_user_command('DyMatrix')
    assert.are.equal(1, updated)
  end)
end)
