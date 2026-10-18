local h = require('helpers')

--- The LuaSnip spec
---@return table
local function luasnip()
  for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/coding/snippet.lua')) do
    if plugin[1] == 'L3MON4D3/LuaSnip' then return plugin end
  end
  error('no LuaSnip spec')
end

describe('plugins.coding.snippet', function()
  local restores

  before_each(function() restores = {} end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('loads the snippet collections through their loaders', function()
    local loaded = {}
    for _, name in ipairs({ 'from_vscode', 'from_snipmate' }) do
      table.insert(
        restores,
        h.stub(package.loaded, 'luasnip.loaders.' .. name, {
          lazy_load = function() table.insert(loaded, name) end,
        })
      )
    end
    for _, dependency in ipairs(luasnip().dependencies) do
      dependency.config()
    end
    assert.same({ 'from_vscode', 'from_snipmate' }, loaded)
  end)

  describe('editing snippet files', function()
    local picker

    before_each(function()
      table.insert(
        restores,
        h.stub(package.loaded, 'luasnip.loaders', {
          edit_snippet_files = function(opts) picker = opts end,
        })
      )
      luasnip().keys[1][2]()
    end)

    it('shortens the configuration and plugin roots', function()
      local config = vim.fn.stdpath('config')
      local plugins = vim.fn.stdpath('data') .. '/lazy'
      assert.equals(
        '$CONFIG/snippets/lua.snippets',
        picker.format(config .. '/snippets/lua.snippets')
      )
      assert.equals(
        '$PLUGINS/vim-snippets/snippets/lua.snippets',
        picker.format(plugins .. '/vim-snippets/snippets/lua.snippets')
      )
      assert.equals(
        '/elsewhere/x.snippets',
        picker.format('/elsewhere/x.snippets')
      )
    end)

    it('offers the file a filetype would get, unless it has one', function()
      local path = vim.fn.stdpath('config') .. '/snippets/zig.snippets'
      assert.same(
        { { '$CONFIG/snippets/zig.snippets (new)', path } },
        picker.extend('zig', { '/elsewhere/zig.snippets' })
      )
      assert.same({}, picker.extend('zig', { path }))
    end)
  end)

  it('jumps and stops snippets through LuaSnip', function()
    local ls =
      { jumpable = false, expandable = false, jumped = 0, unlinked = 0 }
    table.insert(
      restores,
      h.stub(package.loaded, 'luasnip', {
        jumpable = function() return ls.jumpable end,
        expand_or_jumpable = function() return ls.expandable end,
        jump = function() ls.jumped = ls.jumped + 1 end,
        unlink_current = function() ls.unlinked = ls.unlinked + 1 end,
      })
    )
    local actions = require('util.cmp').actions
    local before = { actions.snippet_forward, actions.snippet_stop }
    local opts = luasnip().opts()
    assert.is_true(opts.history)
    assert.is_nil(actions.snippet_forward())
    assert.is_nil(actions.snippet_stop())
    ls.jumpable, ls.expandable = true, true
    assert.is_true(actions.snippet_forward())
    vim.wait(200, function() return ls.jumped == 1 end, 5)
    assert.equals(1, ls.jumped)
    assert.is_true(actions.snippet_stop())
    assert.equals(1, ls.unlinked)
    actions.snippet_forward, actions.snippet_stop = before[1], before[2]
  end)
end)
