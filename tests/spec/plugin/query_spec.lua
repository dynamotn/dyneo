local h = require('helpers')

describe('plugin/query', function()
  it('hands :DyQuery its expression', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.query', {
      command = function(args) table.insert(calls, args.args) end,
    })
    dofile(h.root .. '/plugin/query.lua')
    vim.cmd('DyQuery .items[] | .name')
    restore()
    vim.api.nvim_del_user_command('DyQuery')
    assert.same({ '.items[] | .name' }, calls)
  end)
end)
