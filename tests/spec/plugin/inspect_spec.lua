local h = require('helpers')

describe('plugin/inspect', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.inspect', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/inspect.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyInspect')
  end)

  it('decodes what is under the cursor, or lists every expiry', function()
    vim.cmd('DyInspect')
    vim.cmd('DyInspect expiry')
    assert.same({ {}, { 'expiry' } }, calls)
    assert.same({ 'expiry' }, vim.fn.getcompletion('DyInspect ', 'cmdline'))
  end)
end)
