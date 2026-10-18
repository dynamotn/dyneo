local h = require('helpers')

describe('plugin/nfr', function()
  it('hands :DyNfr its terms', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.nfr', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/nfr.lua')
    vim.cmd('DyNfr 99.9 99.95')
    restore()
    vim.api.nvim_del_user_command('DyNfr')
    assert.same({ { '99.9', '99.95' } }, calls)
  end)
end)
