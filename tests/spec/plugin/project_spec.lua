local h = require('helpers')

describe('plugin/project', function()
  it('opens the page on :DyProject', function()
    local opened = 0
    local restore = h.stub(package.loaded, 'tools.project', {
      open = function() opened = opened + 1 end,
    })
    dofile(h.root .. '/plugin/project.lua')
    vim.cmd('DyProject')
    restore()
    vim.api.nvim_del_user_command('DyProject')
    assert.are.equal(1, opened)
  end)
end)
