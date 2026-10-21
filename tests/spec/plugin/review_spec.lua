local h = require('helpers')

describe('plugin/review', function()
  local untrusted, restore

  before_each(function()
    h.unload('util.untrusted')
    untrusted = require('util.untrusted')
    restore = h.stub(package.loaded, 'tools.review', {
      command = function() error('the module loaded') end,
    })
    dofile(h.root .. '/plugin/review.lua')
  end)

  after_each(function()
    restore()
    pcall(vim.api.nvim_del_user_command, 'DyReview')
    h.unload('util.untrusted')
  end)

  it('holds every review worktree from startup', function()
    assert.is_true(
      untrusted.held('/x/repo/.worktrees/dyreview-github-7/src/a.lua')
    )
    assert.is_false(untrusted.held('/x/repo/.worktrees/feature/a.lua'))
    assert.is_false(untrusted.held('/x/repo/src/a.lua'))
  end)

  it('completes subcommands without loading the module', function()
    package.loaded['tools.review'] = nil
    local found = vim.fn.getcompletion('DyReview s', 'cmdline')
    assert.same({ 'submit', 'since' }, found)
    assert.is_nil(package.loaded['tools.review'])
  end)
end)
