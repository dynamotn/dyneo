local h = require('helpers')

describe('plugin/tfplan', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.tfplan', {
      SUBCOMMANDS = { 'plan', 'clear' },
      command = function(args) table.insert(calls, { 'command', args.fargs }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/tfplan.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyTfPlan')
    vim.api.nvim_del_augroup_by_name('dy_tfplan')
    vim.cmd('silent! %bwipeout!')
  end)

  it('hands the command its subcommand, and completes them', function()
    vim.cmd('DyTfPlan clear')
    assert.same({ { 'command', { 'clear' } } }, calls)
    assert.same(
      { 'plan', 'clear' },
      vim.fn.getcompletion('DyTfPlan ', 'cmdline')
    )
  end)

  it('attaches to a Terraform buffer', function()
    local tf = h.buffer({ filetype = 'terraform' })
    h.buffer({ filetype = 'hcl' })
    assert.same({ { 'attach', tf } }, calls)
  end)
end)
