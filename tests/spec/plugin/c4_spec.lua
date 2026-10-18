local h = require('helpers')

describe('plugin/c4', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.c4', {
      show = function(view) table.insert(calls, { 'show', view }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/c4.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyC4')
    vim.api.nvim_del_augroup_by_name('dy_c4')
    vim.cmd('silent! %bwipeout!')
  end)

  it('shows the view named, or the default one', function()
    vim.cmd('DyC4')
    vim.cmd('DyC4 index')
    assert.same({ { 'show' }, { 'show', 'index' } }, calls)
  end)

  it('attaches to a LikeC4 buffer only', function()
    h.buffer({ filetype = 'yaml' })
    local model = h.buffer({ filetype = 'likec4' })
    assert.same({ { 'attach', model } }, calls)
  end)
end)
