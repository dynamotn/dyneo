local h = require('helpers')

describe('plugin/threat', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.threat', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/threat.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyThreat')
  end)

  it('hands the command its words', function()
    vim.cmd('DyThreat new payments')
    assert.same({ { 'new', 'payments' } }, calls)
  end)

  it('completes `new` first, and nothing after it', function()
    assert.same({ 'new' }, vim.fn.getcompletion('DyThreat ', 'cmdline'))
    assert.same({}, vim.fn.getcompletion('DyThreat new ', 'cmdline'))
  end)
end)
