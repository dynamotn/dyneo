local h = require('helpers')

describe('plugin/promql', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.promql', {
      SUBCOMMANDS = { 'test' },
      command = function(args)
        table.insert(calls, { args.fargs, args.range, args.line1, args.line2 })
      end,
    })
    dofile(h.root .. '/plugin/promql.lua')
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'a', 'b', 'c' } }))
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyPromQL')
    vim.cmd('silent! %bwipeout!')
  end)

  it('hands :DyPromQL its range and subcommand', function()
    vim.cmd('DyPromQL')
    vim.cmd('2,3DyPromQL')
    vim.cmd('DyPromQL test')
    assert.same({
      { {}, 0, 1, 1 },
      { {}, 2, 2, 3 },
      { { 'test' }, 0, 1, 1 },
    }, calls)
    assert.same({ 'test' }, vim.fn.getcompletion('DyPromQL ', 'cmdline'))
  end)
end)
