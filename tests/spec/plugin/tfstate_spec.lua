local h = require('helpers')

describe('plugin/tfstate', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.tfstate', {
      SUBCOMMANDS = { show = true, drift = true, import = true },
      command = function(args) table.insert(calls, { 'command', args.fargs }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/tfstate.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyTfState')
    vim.api.nvim_del_augroup_by_name('dy_tfstate')
    vim.cmd('silent! %bwipeout!')
  end)

  it('hands the command its subcommand, and completes them sorted', function()
    vim.cmd('DyTfState drift')
    assert.same({ { 'command', { 'drift' } } }, calls)
    assert.same(
      { 'drift', 'import', 'show' },
      vim.fn.getcompletion('DyTfState ', 'cmdline')
    )
  end)

  it('attaches to a Terraform buffer', function()
    local tf = h.buffer({ filetype = 'tf' })
    h.buffer({ filetype = 'hcl' })
    assert.same({ { 'attach', tf } }, calls)
  end)
end)
