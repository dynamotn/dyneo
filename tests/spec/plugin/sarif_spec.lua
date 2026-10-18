local h = require('helpers')

describe('plugin/sarif', function()
  it('hands :DySarif the report named', function()
    local calls = {}
    local restore = h.stub(package.loaded, 'tools.sarif', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/sarif.lua')
    vim.cmd('DySarif')
    vim.cmd('DySarif report.sarif')
    restore()
    assert.are.equal('file', vim.api.nvim_get_commands({}).DySarif.complete)
    vim.api.nvim_del_user_command('DySarif')
    assert.same({ {}, { 'report.sarif' } }, calls)
  end)
end)
