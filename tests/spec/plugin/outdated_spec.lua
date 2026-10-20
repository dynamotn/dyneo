local h = require('helpers')

describe('plugin/outdated', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.outdated', {
      SUBCOMMANDS = { 'bump', 'clear' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/outdated.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyOutdated')
  end)

  it('hands :DyOutdated its subcommand, and completes them', function()
    vim.cmd('DyOutdated')
    vim.cmd('DyOutdated bump')
    assert.same({ {}, { 'bump' } }, calls)
    assert.same(
      { 'bump', 'clear' },
      vim.fn.getcompletion('DyOutdated ', 'cmdline')
    )
  end)
end)
