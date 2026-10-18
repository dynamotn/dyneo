local h = require('helpers')

describe('plugins.ui.render', function()
  local restore

  before_each(function() h.globals() end)
  after_each(function() restore() end)

  it('makes the highlight groups helpview left to VimEnter', function()
    local group = vim.api.nvim_create_augroup('dy_test_helpview', {})
    local fired = 0
    vim.api.nvim_create_autocmd('VimEnter', {
      group = group,
      callback = function() fired = fired + 1 end,
    })
    local setup_opts
    restore = h.stub(package.loaded, 'helpview', {
      au = group,
      setup = function(opts) setup_opts = opts end,
    })
    local helpview
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/ui/render.lua')) do
      if spec[1] == 'OXY2DEV/helpview.nvim' then helpview = spec end
    end
    assert.equals('help', helpview.ft)
    helpview.config(nil, { opt = true })
    assert.same({ opt = true }, setup_opts)
    assert.equals(1, fired)
    vim.api.nvim_del_augroup_by_id(group)
  end)
end)
