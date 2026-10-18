local h = require('helpers')

describe('plugin/runbook', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.runbook', {
      SUBCOMMANDS = { 'run', 'all', 'clear' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/runbook.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyRunbook')
  end)

  it('hands the command its subcommand', function()
    vim.cmd('DyRunbook')
    vim.cmd('DyRunbook all')
    assert.same({ {}, { 'all' } }, calls)
  end)

  it('completes the subcommands that match', function()
    assert.same({ 'all' }, vim.fn.getcompletion('DyRunbook a', 'cmdline'))
    assert.same(
      { 'run', 'all', 'clear' },
      vim.fn.getcompletion('DyRunbook ', 'cmdline')
    )
  end)
end)
