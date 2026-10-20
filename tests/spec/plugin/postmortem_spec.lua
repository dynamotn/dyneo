local h = require('helpers')

describe('plugin/postmortem', function()
  it('hands :DyPostmortem its words, and completes new', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.postmortem', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/postmortem.lua')
    vim.cmd('DyPostmortem new API down')
    vim.cmd('DyPostmortem')
    local first = vim.fn.getcompletion('DyPostmortem ', 'cmdline')
    local title = vim.fn.getcompletion('DyPostmortem new ', 'cmdline')
    restore()
    vim.api.nvim_del_user_command('DyPostmortem')
    assert.same({ { 'new', 'API', 'down' }, {} }, calls)
    assert.same({ 'new' }, first)
    assert.same({}, title)
  end)
end)
