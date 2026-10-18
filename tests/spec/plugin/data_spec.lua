local h = require('helpers')

describe('plugin/data', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.data', {
      command = function(args) table.insert(calls, { 'command', args.fargs }) end,
      complete = function(lead, line)
        table.insert(calls, { 'complete', lead, line })
        return { 'summary' }
      end,
      read = function(bufnr) table.insert(calls, { 'read', bufnr }) end,
    })
    dofile(h.root .. '/plugin/data.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyData')
    vim.api.nvim_del_augroup_by_name('dy_data')
    vim.cmd('silent! %bwipeout!')
  end)

  it('hands the command its words, and completes through the tool', function()
    vim.cmd('DyData summary')
    assert.same({ 'summary' }, vim.fn.getcompletion('DyData su', 'cmdline'))
    assert.same({
      { 'command', { 'summary' } },
      { 'complete', 'su', 'DyData su' },
    }, calls)
  end)

  it('opens a Parquet file as its summary', function()
    vim.cmd.edit('/nowhere/table.parquet')
    assert.same({ { 'read', vim.api.nvim_get_current_buf() } }, calls)
  end)
end)
