local h = require('helpers')

describe('plugin/envdiff', function()
  it('hands :DyEnvDiff the other file', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.envdiff', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/envdiff.lua')
    vim.cmd('DyEnvDiff values-prod.yaml')
    vim.cmd('DyEnvDiff')
    restore()
    vim.api.nvim_del_user_command('DyEnvDiff')
    assert.same({ { 'values-prod.yaml' }, {} }, calls)
  end)
end)
