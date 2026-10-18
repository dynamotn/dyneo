local h = require('helpers')

local file = h.root .. '/lua/plugins/ui/highlight.lua'

---@param name string
---@return table
local function spec_of(name)
  for _, spec in ipairs(dofile(file)) do
    if spec[1] == name then return spec end
  end
  error('no spec ' .. name)
end

describe('plugins.ui.highlight', function()
  local restores

  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    h.globals()
    restores = {}
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  describe('mini.hipatterns', function()
    local hipatterns

    before_each(function()
      hipatterns = {
        gen_highlighter = {
          hex_color = function(opts) return { hex = opts } end,
        },
        toggle = function() hipatterns.toggled = true end,
        setup = function(opts) hipatterns.setup_opts = opts end,
        update = function(...) hipatterns.updated = { ... } end,
      }
    end)

    it('toggles from its key', function()
      stub(package.loaded, 'mini.hipatterns', hipatterns)
      spec_of('nvim-mini/mini.hipatterns').keys[1][2]()
      assert.is_true(hipatterns.toggled)
    end)

    it('checks the line left on leaving insert mode', function()
      stub(package.loaded, 'mini.hipatterns', nil)
      spec_of('nvim-mini/mini.hipatterns').init()
      -- Not loaded yet: nothing to update, and nothing loads it
      vim.api.nvim_exec_autocmds('InsertLeave', {})
      assert.is_nil(package.loaded['mini.hipatterns'])

      stub(package.loaded, 'mini.hipatterns', hipatterns)
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'a', 'b', 'c' } }))
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_exec_autocmds('InsertLeave', {})
      assert.same({ 0, 2, 2 }, hipatterns.updated)
      vim.api.nvim_del_augroup_by_name('dy_trailing_whitespace')
    end)

    it('expands a shorthand hex colour', function()
      stub(package.loaded, 'mini.hipatterns', hipatterns)
      stub(_G, 'MiniHipatterns', {
        compute_hex_color_group = function(color, style)
          return 'group:' .. color .. ':' .. style
        end,
      })
      local opts = spec_of('nvim-mini/mini.hipatterns').opts()
      assert.same({ hex = { priority = 2000 } }, opts.highlighters.hex_color)
      local group = opts.highlighters.shorthand.group
      assert.equals(
        'group:#aabbcc:bg',
        group(nil, nil, { full_match = '#abc' })
      )
      -- `#add` is a word, not a colour
      assert.is_nil(group(nil, nil, { full_match = '#add' }))
    end)

    it('spares the line being typed from the trailing space mark', function()
      stub(package.loaded, 'mini.hipatterns', hipatterns)
      local group =
        spec_of('nvim-mini/mini.hipatterns').opts().highlighters.trailing_whitespace.group
      local bufnr = h.buffer({ lines = { 'a ', 'b ' } })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      assert.equals('DyTrailingWhitespace', group(bufnr, nil, { line = 1 }))

      stub(vim.api, 'nvim_get_mode', function() return { mode = 'i' } end)
      assert.is_nil(group(bufnr, nil, { line = 1 }))
      -- Another line, or another buffer, is still marked
      assert.equals('DyTrailingWhitespace', group(bufnr, nil, { line = 2 }))
      assert.equals(
        'DyTrailingWhitespace',
        group(h.buffer({}), nil, { line = 1 })
      )
    end)

    it('turns the tailwind option into a highlighter', function()
      stub(package.loaded, 'mini.hipatterns', hipatterns)
      local spec = spec_of('nvim-mini/mini.hipatterns')
      local opts = { tailwind = { enabled = false }, highlighters = {} }
      spec.config(nil, opts)
      assert.is_nil(hipatterns.setup_opts.highlighters.tailwind)

      opts = spec.opts()
      spec.config(nil, opts)
      assert.equals(opts, hipatterns.setup_opts)
      assert.equals('function', type(opts.highlighters.tailwind.pattern))
    end)
  end)

  it('colours rainbow delimiters by the global strategy', function()
    stub(package.loaded, 'rainbow-delimiters', {
      strategy = { global = 'global', ['local'] = 'local' },
    })
    local opts = spec_of('HiPhish/rainbow-delimiters.nvim').opts()
    assert.equals('global', opts.strategy[''])
    assert.equals('local', opts.strategy.vim)
    assert.equals('rainbow-delimiters', opts.query[''])
  end)

  describe('markview', function()
    local markview, actions, attached

    before_each(function()
      attached = {}
      markview = { setup = function(opts) markview.setup_opts = opts end }
      actions = {
        attach = function(...)
          table.insert(attached, { ... })
          return 'attached'
        end,
      }
      stub(package.loaded, 'markview', markview)
      stub(package.loaded, 'markview.presets', {
        headings = { glow = 'glow' },
      })
      stub(package.loaded, 'markview.actions', actions)
    end)

    it('previews every markup filetype of the languages', function()
      local spec = spec_of('OXY2DEV/markview.nvim')
      assert.is_true(vim.list_contains(spec.ft, 'markdown'))
      assert.is_true(vim.list_contains(spec.ft, 'Avante'))
      assert.equals(spec.ft, spec.opts.preview.filetypes)
    end)

    it('sets up with the glow headings', function()
      local spec = spec_of('OXY2DEV/markview.nvim')
      spec.config(nil, spec.opts)
      assert.equals('glow', markview.setup_opts.markdown.headings)
      assert.is_true(markview.setup_opts.html.enable)
    end)

    it('attaches only once the parser is there', function()
      local spec = spec_of('OXY2DEV/markview.nvim')
      spec.config(nil, spec.opts)
      assert.is_not.equals(actions.attach, attached)

      -- No language for the filetype: left alone
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      assert.is_nil(actions.attach(0))
      assert.same({}, attached)

      vim.bo[bufnr].filetype = 'markdown'
      local added = false
      stub(vim.treesitter.language, 'add', function() return added end)
      assert.is_nil(actions.attach(nil))
      assert.same({}, attached)

      added = true
      assert.equals('attached', actions.attach(bufnr, 'extra'))
      assert.same({ { bufnr, 'extra' } }, attached)

      -- A parser that fails to load is no parser
      stub(vim.treesitter.language, 'add', function() error('no parser') end)
      assert.is_nil(actions.attach(0))
      assert.equals(1, #attached)
    end)
  end)
end)
