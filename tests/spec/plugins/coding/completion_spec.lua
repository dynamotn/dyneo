local h = require('helpers')

--- The spec of `name` in `plugins/coding/completion.lua`
---@param name string
---@return table
local function spec_of(name)
  for _, plugin in
    ipairs(dofile(h.root .. '/lua/plugins/coding/completion.lua'))
  do
    if plugin[1] == name then return plugin end
  end
  error('no spec for ' .. name)
end

describe('plugins.coding.completion: cmp-dynamic', function()
  it('registers dates and times in both orders', function()
    local registered
    local restore = h.stub(package.loaded, 'cmp_dynamic', {
      register = function(items) registered = items end,
    })
    spec_of('uga-rosa/cmp-dynamic').config()
    restore()
    local by_label = {}
    for _, item in ipairs(registered) do
      by_label[item.label] = by_label[item.label] or {}
      table.insert(by_label[item.label], item.insertText())
    end
    assert.matches('^%d%d/%d%d/%d%d%d%d$', by_label.today[1])
    assert.matches('^%d%d%d%d/%d%d/%d%d$', by_label.today[2])
    assert.matches('^%d%d:%d%d:%d%d %d%d/%d%d/%d%d%d%d$', by_label.now[1])
    assert.matches('^%d%d%d%d_%d%d_%d%d_%d%d_%d%d$', by_label.now[2])
    assert.matches('^%d+$', by_label.timestamp[1])
  end)
end)

describe('plugins.coding.completion: blink.cmp', function()
  local restores, blink

  before_each(function()
    h.globals()
    restores = {}
    blink = spec_of('saghen/blink.cmp')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('names its sources, keeping those other specs named', function()
    DyNeo.completion_sources = { Avante = 'ai' }
    blink.init()
    assert.equals('ai', DyNeo.completion_sources.Avante)
    assert.equals('「PATH」', DyNeo.completion_sources.Path)
  end)

  it('completes words from the file buffers only', function()
    local file = h.buffer({ lines = { 'word' } })
    local scratch = vim.api.nvim_create_buf(false, true)
    vim.bo[scratch].buftype = 'nofile'
    local bufs = blink.opts.sources.providers.buffer.opts.get_bufnrs()
    assert.is_true(vim.list_contains(bufs, file))
    assert.is_false(vim.list_contains(bufs, scratch))
  end)

  it('completes project paths from the project root', function()
    table.insert(
      restores,
      h.stub(require('util.root'), 'get', function() return '/proj' end)
    )
    assert.equals(
      '/proj',
      blink.opts.sources.providers.project_path.opts.get_cwd({})
    )
  end)

  it('forgives no typo, and picks the sources by context', function()
    assert.equals(0, blink.opts.fuzzy.max_typos())
    -- No Treesitter node in a scratch buffer: the common sources
    assert.same(require('util.cmp').sources('*'), blink.opts.sources.default())
    -- Not on a command line: nothing
    assert.same({}, blink.opts.cmdline.sources())
  end)

  it('runs the Tab actions in turn, then falls back', function()
    local actions = require('util.cmp').actions
    local before = actions.ai_accept
    actions.ai_accept = function() return true end
    assert.is_true(blink.opts.keymap['<Tab>'][1]())
    actions.ai_accept = nil
    actions.ai_nes = nil
    assert.is_nil(blink.opts.keymap['<Tab>'][1]())
    actions.ai_accept = before
  end)

  it('accepts the ghost text of the command line with Right', function()
    local visible, accepted = false, 0
    local cmp = {
      is_ghost_text_visible = function() return visible end,
      accept = function()
        accepted = accepted + 1
        return true
      end,
    }
    local right = blink.opts.cmdline.keymap['<Right>'][1]
    assert.is_nil(right(cmp))
    visible = true
    assert.is_true(right(cmp))
    assert.equals(1, accepted)
  end)

  describe('menu', function()
    local components, icons

    before_each(function()
      components = blink.opts.completion.menu.draw.components
      icons = require('config.defaults').icons.kinds
      table.insert(
        restores,
        h.stub(package.loaded, 'nvim-web-devicons', {
          get_icon = function(name)
            if name:match('%.lua$') then return '', 'DevIconLua' end
          end,
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'lspkind', {
          symbol_map = { Function = 'ƒ' },
        })
      )
    end)

    it('draws a path item with the icon of its file', function()
      local ctx = {
        source_name = 'Path',
        label = 'init.lua',
        kind_icon = 'x',
        kind_hl = 'BlinkCmpKindFile',
        icon_gap = ' ',
      }
      assert.equals(' ', components.kind_icon.text(ctx))
      assert.equals('DevIconLua', components.kind_icon.highlight(ctx))
      -- A file devicons does not know keeps blink's icon
      ctx.label = 'README'
      assert.equals('x ', components.kind_icon.text(ctx))
      assert.equals('BlinkCmpKindFile', components.kind_icon.highlight(ctx))
    end)

    it('draws a source with an icon of its own, else by kind', function()
      local ctx = {
        source_name = 'LSP',
        label = 'print',
        kind = 'Function',
        kind_icon = 'x',
        kind_hl = 'BlinkCmpKindFunction',
        icon_gap = ' ',
      }
      assert.equals('ƒ ', components.kind_icon.text(ctx))
      assert.equals('BlinkCmpKindFunction', components.kind_icon.highlight(ctx))
      ctx.kind = 'Unknown'
      assert.equals(' ', components.kind_icon.text(ctx))
      local named = vim.tbl_keys(icons)[1]
      ctx.source_name = named
      assert.equals(icons[named] .. ' ', components.kind_icon.text(ctx))
    end)

    it('labels the source, every path source alike', function()
      DyNeo.completion_sources = { Path = 'P', LSP = 'L' }
      local text = components.source_name.text
      assert.equals('P', text({ source_name = 'Path' }))
      assert.equals('P', text({ source_name = 'fuzzy_path' }))
      assert.equals('L', text({ source_name = 'LSP' }))
      assert.equals('custom', text({ source_name = 'custom' }))
    end)
  end)

  describe('config', function()
    local set_up, kinds

    before_each(function()
      kinds = { 'Text', Text = 1 }
      table.insert(
        restores,
        h.stub(package.loaded, 'blink.cmp', {
          setup = function(opts) set_up = opts end,
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'blink.cmp.types', {
          CompletionItemKind = kinds,
        })
      )
    end)

    it('runs the nvim-cmp sources through blink.compat', function()
      local opts = {
        sources = {
          compat = { 'calc', 'dynamic' },
          default = { 'lsp', 'calc' },
          providers = { calc = { score_offset = 3 } },
        },
      }
      blink.config(nil, opts)
      assert.equals(opts, set_up)
      assert.is_nil(opts.sources.compat)
      assert.same(
        { name = 'calc', module = 'blink.compat.source', score_offset = 3 },
        opts.sources.providers.calc
      )
      assert.same(
        { name = 'dynamic', module = 'blink.compat.source' },
        opts.sources.providers.dynamic
      )
      -- Added to the defaults once, after what was there
      assert.same({ 'lsp', 'calc', 'dynamic' }, opts.sources.default)
    end)

    it('leaves a default given as a function alone', function()
      local default = function() return {} end
      local opts = {
        sources = { compat = { 'calc' }, default = default, providers = {} },
      }
      blink.config(nil, opts)
      assert.equals(default, opts.sources.default)
    end)

    it('adds a provider kind of its own to the completion kinds', function()
      local transformed
      local provider = {
        kind = 'Emoji',
        transform_items = function(_, items)
          transformed = items
          return items
        end,
      }
      local plain = { kind = 'Plain' }
      local opts =
        { sources = { providers = { emoji = provider, plain = plain } } }
      blink.config(nil, opts)
      assert.is_nil(provider.kind)
      assert.equals(kinds.Emoji, kinds[kinds.Emoji] and kinds.Emoji)
      assert.equals('Emoji', kinds[kinds.Emoji])
      assert.equals('Plain', kinds[kinds.Plain])
      local icons = require('config.defaults').icons.kinds
      local named = vim.tbl_keys(icons)[1]
      local items = {
        { kind = 1, kind_name = named },
        { kind = 1, kind_icon = 'k' },
        { kind = 1 },
      }
      assert.equals(items, provider.transform_items({}, items))
      assert.equals(items, transformed)
      assert.equals(kinds.Emoji, items[1].kind)
      assert.equals(icons[named], items[1].kind_icon)
      assert.equals('k', items[2].kind_icon)
      assert.is_nil(items[3].kind_icon)
      -- Without a transform of its own, the items are only re-kinded
      assert.equals(
        kinds.Plain,
        plain.transform_items({}, { { kind = 1 } })[1].kind
      )
    end)
  end)
end)
