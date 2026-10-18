local h = require('helpers')

describe('plugin/architecture', function()
  it('opens the diagram on :DyArchitecture', function()
    local opened = 0
    local restore = h.stub(package.loaded, 'tools.architecture', {
      open = function() opened = opened + 1 end,
    })
    dofile(h.root .. '/plugin/architecture.lua')
    vim.cmd('DyArchitecture')
    restore()
    vim.api.nvim_del_user_command('DyArchitecture')
    assert.are.equal(1, opened)
  end)
end)
