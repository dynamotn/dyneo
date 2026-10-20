local h = require('helpers')

describe('plugin/images', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.images', {
      scan = function(bufnr) table.insert(calls, { 'scan', bufnr }) end,
      pin = function(bufnr) table.insert(calls, { 'pin', bufnr }) end,
      verify = function(bufnr) table.insert(calls, { 'verify', bufnr }) end,
    })
    dofile(h.root .. '/plugin/images.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyImageScan')
    vim.api.nvim_del_user_command('DyImagePin')
    vim.api.nvim_del_user_command('DyImageVerify')
  end)

  it('scans, pins and verifies the current buffer', function()
    vim.cmd('DyImageScan')
    vim.cmd('DyImagePin')
    vim.cmd('DyImageVerify')
    assert.same({ { 'scan', 0 }, { 'pin', 0 }, { 'verify', 0 } }, calls)
  end)
end)
