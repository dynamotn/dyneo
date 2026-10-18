local h = require('helpers')

describe('plugin/war', function()
  it('hands :DyWar its subcommand, and completes `new`', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.war', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/war.lua')
    vim.cmd('DyWar')
    vim.cmd('DyWar new')
    local completed = vim.fn.getcompletion('DyWar ', 'cmdline')
    restore()
    vim.api.nvim_del_user_command('DyWar')
    assert.same({ {}, { 'new' } }, calls)
    assert.same({ 'new' }, completed)
  end)
end)
