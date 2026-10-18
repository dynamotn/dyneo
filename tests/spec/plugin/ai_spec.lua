local h = require('helpers')

describe('plugin/ai', function()
  local calls, completed, restore
  before_each(function()
    calls, completed = {}, {}
    restore = h.stub(package.loaded, 'tools.ai', {
      command = function(args) table.insert(calls, args) end,
      complete = function(lead, line)
        table.insert(completed, { lead, line })
        return { 'explain' }
      end,
    })
    dofile(h.root .. '/plugin/ai.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyAi')
  end)

  it('hands the command its range and words', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'a', 'b', 'c' } }))
    vim.cmd('1,2DyAi explain this')
    assert.are.equal(1, #calls)
    assert.same({ 'explain', 'this' }, calls[1].fargs)
    assert.are.equal(2, calls[1].range)
    assert.are.equal(1, calls[1].line1)
    assert.are.equal(2, calls[1].line2)
    vim.cmd('bwipeout!')
  end)

  it('completes through the tool', function()
    assert.same({ 'explain' }, vim.fn.getcompletion('DyAi ex', 'cmdline'))
    assert.same({ { 'ex', 'DyAi ex' } }, completed)
  end)
end)
