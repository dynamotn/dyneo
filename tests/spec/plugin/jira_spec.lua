local h = require('helpers')

describe('plugin/jira', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.jira', {
      SUBCOMMANDS = { 'pick', 'branch', 'move', 'log', 'copy' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/jira.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyJira')
  end)

  it('hands the command its words', function()
    vim.cmd('DyJira log 2h')
    assert.same({ { 'log', '2h' } }, calls)
  end)

  it('completes the subcommand, and nothing after it', function()
    assert.same(
      { 'pick', 'branch', 'move', 'log', 'copy' },
      vim.fn.getcompletion('DyJira ', 'cmdline')
    )
    assert.same({ 'branch' }, vim.fn.getcompletion('DyJira br', 'cmdline'))
    assert.same({}, vim.fn.getcompletion('DyJira log ', 'cmdline'))
    assert.same({}, vim.fn.getcompletion('DyJira log 2', 'cmdline'))
  end)
end)
