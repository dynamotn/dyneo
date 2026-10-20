local h = require('helpers')

describe('plugin/history', function()
  it('hands :DyHistory its range', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.history', {
      command = function(args)
        table.insert(calls, { args.range, args.line1, args.line2 })
      end,
    })
    dofile(h.root .. '/plugin/history.lua')
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'a', 'b', 'c' } }))
    vim.cmd('DyHistory')
    vim.cmd('2,3DyHistory')
    restore()
    vim.api.nvim_del_user_command('DyHistory')
    vim.cmd('silent! %bwipeout!')
    assert.same({ { 0, 1, 1 }, { 2, 2, 3 } }, calls)
  end)
end)
