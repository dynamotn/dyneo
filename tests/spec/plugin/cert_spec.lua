local h = require('helpers')

describe('plugin/cert', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.cert', {
      SUBCOMMANDS = { 'host' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/cert.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyCert')
  end)

  it('hands :DyCert a file, or a host', function()
    vim.cmd('DyCert my\\ cert.pem')
    vim.cmd('DyCert host example.com:8443')
    assert.same({ { 'my cert.pem' }, { 'host', 'example.com:8443' } }, calls)
  end)

  it('completes host before files, and no file after it', function()
    assert.equals('host', vim.fn.getcompletion('DyCert ', 'cmdline')[1])
    assert.same({}, vim.fn.getcompletion('DyCert host ', 'cmdline'))
  end)
end)
