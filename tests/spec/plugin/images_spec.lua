local h = require('helpers')

describe('plugin/images', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.images', {
      scan = function(bufnr) table.insert(calls, { 'scan', bufnr }) end,
      pin = function(bufnr) table.insert(calls, { 'pin', bufnr }) end,
    })
    dofile(h.root .. '/plugin/images.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyImageScan')
    vim.api.nvim_del_user_command('DyImagePin')
  end)

  it('scans and pins the current buffer', function()
    vim.cmd('DyImageScan')
    vim.cmd('DyImagePin')
    assert.same({ { 'scan', 0 }, { 'pin', 0 } }, calls)
  end)
end)
