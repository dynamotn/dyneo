-- With `auto_integrations` off, catppuccin colours exactly the plugins named
-- in `lua/plugins/ui/colorscheme.lua`. A plugin dropped from the spec leaves
-- its integration behind, compiled into every colorscheme load, and a plugin
-- swapped for another (nvim-cmp for blink) leaves the new one uncoloured.
local h = require('helpers')

--- Integration to the plugins, by their lazy.nvim name, any of which it
--- colours. A new integration needs its plugin added here.
local plugins_of = {
  avante = { 'avante.nvim' },
  blink_cmp = { 'blink.cmp' },
  dadbod_ui = { 'vim-dadbod-ui' },
  dap = { 'nvim-dap' },
  diffview = { 'diffview-plus.nvim' },
  dropbar = { 'dropbar.nvim' },
  flash = { 'flash.nvim' },
  gitsigns = { 'gitsigns.nvim' },
  grug_far = { 'grug-far.nvim' },
  harpoon = { 'harpoon' },
  lsp_trouble = { 'trouble.nvim' },
  markview = { 'markview.nvim' },
  mason = { 'mason.nvim' },
  mini = { 'mini.ai', 'mini.icons', 'mini.surround', 'mini.hipatterns' },
  neotest = { 'neotest' },
  noice = { 'noice.nvim' },
  octo = { 'octo.nvim' },
  overseer = { 'overseer.nvim' },
  rainbow_delimiters = { 'rainbow-delimiters.nvim' },
  snacks = { 'snacks.nvim' },
  treesitter_context = { 'nvim-treesitter-context' },
  which_key = { 'which-key.nvim' },
}

describe('colorscheme', function()
  local opts, locked

  before_each(function()
    h.globals()
    opts = dofile(h.root .. '/lua/plugins/ui/colorscheme.lua')[1].opts
    locked = vim.json.decode(
      table.concat(vim.fn.readfile(h.root .. '/lazy-lock.json'), '\n')
    )
  end)

  it('only names integrations of plugins in the configuration', function()
    local stale = {}
    for name in pairs(opts.integrations) do
      local found = false
      for _, plugin in ipairs(plugins_of[name] or {}) do
        found = found or locked[plugin] ~= nil
      end
      if not found then table.insert(stale, name) end
    end
    table.sort(stale)
    assert.same({}, stale)
  end)

  it('colours the completion menu blink draws', function()
    assert.is_true(opts.integrations.blink_cmp)
    local source = table.concat(
      vim.fn.readfile(h.root .. '/lua/plugins/ui/colorscheme.lua'),
      '\n'
    )
    assert.is_nil(source:find('CmpItem', 1, true))
  end)

  it('draws the Avante sidebar like the other panels', function()
    -- Catppuccin is not on the test runtimepath: any colour does
    package.loaded['catppuccin.utils.colors'] =
      { lighten = function() return '#000000' end }
    local colors = setmetatable(
      {},
      { __index = function() return '#000000' end }
    )
    local groups = opts.custom_highlights(colors)
    package.loaded['catppuccin.utils.colors'] = nil
    assert.same({ link = 'Normal' }, groups.AvanteSidebarNormal)
    assert.same({ link = 'WinSeparator' }, groups.AvanteSidebarWinSeparator)
    assert.same(
      { link = 'WinSeparator' },
      groups.AvanteSidebarWinHorizontalSeparator
    )
    assert.same({ link = 'SnacksInputNormal' }, groups.AvantePromptInput)
  end)
end)
