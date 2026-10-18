local h = require('helpers')

describe('plugin/deps', function()
  it('checks the dependency rules on :DyDeps', function()
    local checked = 0
    local restore = h.stub(package.loaded, 'tools.deps', {
      check = function() checked = checked + 1 end,
    })
    dofile(h.root .. '/plugin/deps.lua')
    vim.cmd('DyDeps')
    restore()
    vim.api.nvim_del_user_command('DyDeps')
    assert.are.equal(1, checked)
  end)
end)
