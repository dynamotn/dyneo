local h = require('helpers')

describe('plugins.coding.clipboard', function()
  local ring, restores

  before_each(function()
    ring = {}
    restores = {}
    local history = { push = function(item) table.insert(ring, item) end }
    for name, module in pairs({
      ['yanky'] = { setup = function() end },
      ['yanky.history'] = history,
    }) do
      table.insert(restores, h.stub(package.loaded, name, module))
    end
    local specs = dofile(h.root .. '/lua/plugins/coding/clipboard.lua')
    specs[1].config(nil, specs[1].opts)
  end)
  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('keeps a yank of a sensitive buffer out of the yank ring', function()
    local secret = h.buffer({ lines = { 'password' } })
    require('util.sensitive').mark(secret, 'decrypted with sops')
    vim.api.nvim_set_current_buf(secret)
    require('yanky.history').push({ regcontents = 'password' })
    assert.same({}, ring)

    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'plain' } }))
    require('yanky.history').push({ regcontents = 'plain' })
    assert.same({ { regcontents = 'plain' } }, ring)
  end)
end)
