local h = require('helpers')

describe('plugin/owners', function()
  it('hands :DyOwners its subcommand, and completes it', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.owners', {
      SUBCOMMANDS = { 'unowned' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/owners.lua')
    vim.cmd('DyOwners')
    vim.cmd('DyOwners unowned')
    local completed = vim.fn.getcompletion('DyOwners ', 'cmdline')
    restore()
    vim.api.nvim_del_user_command('DyOwners')
    assert.same({ {}, { 'unowned' } }, calls)
    assert.same({ 'unowned' }, completed)
  end)
end)
