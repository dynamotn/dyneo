local h = require('helpers')

describe('plugin/actions', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.actions', {
      pin = function(bufnr) table.insert(calls, { 'pin', bufnr }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/actions.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyActionsPin')
    vim.api.nvim_del_augroup_by_name('dy_actions')
    vim.cmd('silent! %bwipeout!')
  end)

  it('pins the current buffer on :DyActionsPin', function()
    vim.cmd('DyActionsPin')
    assert.same({ { 'pin', 0 } }, calls)
  end)

  it('attaches the tool to a workflow, and to nothing else', function()
    local plain = h.buffer({ filetype = 'yaml' })
    assert.same({}, calls)
    local workflow = h.buffer({ filetype = 'yaml.gh-action' })
    assert.same({ { 'attach', workflow } }, calls)
    assert.are_not.equal(plain, workflow)
  end)
end)
