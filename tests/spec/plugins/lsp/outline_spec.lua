local h = require('helpers')

describe('plugins.lsp.outline', function()
  local specs, restore

  before_each(function()
    specs = dofile(h.root .. '/lua/plugins/lsp/outline.lua')
    -- Only the shipped icons are read from the plugin
    restore = h.stub(package.loaded, 'outline.config', {
      defaults = {
        symbols = {
          icons = {
            File = { icon = 'F', hl = '@text.uri' },
            Key = { icon = 'k', hl = '@type' },
            Unknown = { icon = '?', hl = '@text' },
          },
        },
      },
    })
  end)
  after_each(function() restore() end)

  ---@param name string
  ---@return table
  local function spec(name)
    for _, plugin in ipairs(specs) do
      if plugin[1] == name then return plugin end
    end
    error('no spec for ' .. name)
  end

  it('draws the symbols with the icons of the config', function()
    local opts = spec('hedyhli/outline.nvim').opts()
    local kinds = require('config.defaults').icons.kinds
    assert.same(
      { icon = kinds.File, hl = '@text.uri' },
      opts.symbols.icons.File
    )
    -- A kind the config has no icon for keeps the plugin's
    assert.same({ icon = '?', hl = '@text' }, opts.symbols.icons.Unknown)
    -- `Key` has an icon of its own only when the config gives it none
    assert.same(
      { icon = kinds.Key or ' ', hl = '@type' },
      opts.symbols.icons.Key
    )
  end)

  it('leaves the control flow of Lua out of the outline', function()
    local filter = spec('hedyhli/outline.nvim').opts().symbols.filter
    assert.is_true(vim.list_contains(filter.default, 'Package'))
    assert.is_false(vim.list_contains(filter.lua, 'Package'))
    assert.is_false(filter.markdown)
  end)

  it('pins the outline to the right edge', function()
    local opts = {}
    spec('folke/edgy.nvim').opts(nil, opts)
    assert.are.equal(1, #opts.right)
    assert.are.equal('Outline', opts.right[1].ft)
    -- Added to what other specs put there
    spec('folke/edgy.nvim').opts(nil, opts)
    assert.are.equal(2, #opts.right)
    assert.are.equal(
      'Outline',
      spec('lualine.nvim').opts.special_filetypes.Outline
    )
  end)
end)
