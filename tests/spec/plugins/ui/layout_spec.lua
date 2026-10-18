local h = require('helpers')

local file = h.root .. '/lua/plugins/ui/layout.lua'

---@param name string
---@return table
local function spec_of(name)
  for _, spec in ipairs(dofile(file)) do
    if spec[1] == name then return spec end
  end
  error('no spec ' .. name)
end

---@param spec table
---@param lhs string
---@return table
local function key_of(spec, lhs)
  for _, key in ipairs(spec.keys) do
    if key[1] == lhs then return key end
  end
  error('no key ' .. lhs)
end

describe('plugins.ui.layout', function()
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

  describe('noice', function()
    it('drives noice from its keys', function()
      local calls = {}
      stub(package.loaded, 'noice', {
        redirect = function(cmd) table.insert(calls, 'redirect:' .. cmd) end,
        cmd = function(what) table.insert(calls, what) end,
      })
      local spec = spec_of('folke/noice.nvim')
      for _, lhs in ipairs({
        '<S-Enter>',
        '<leader>snl',
        '<leader>snh',
        '<leader>sna',
        '<leader>snd',
        '<leader>snt',
      }) do
        key_of(spec, lhs)[2]()
      end
      assert.same(
        { 'redirect:', 'last', 'history', 'all', 'dismiss', 'pick' },
        calls
      )
      assert.equals('', key_of(spec, '<leader>sn')[2])
    end)

    it('scrolls a hover window, or the buffer when there is none', function()
      local scrolled, by = false, {}
      stub(package.loaded, 'noice.lsp', {
        scroll = function(n)
          table.insert(by, n)
          return scrolled
        end,
      })
      local spec = spec_of('folke/noice.nvim')
      assert.equals('<c-f>', key_of(spec, '<c-f>')[2]())
      assert.equals('<c-b>', key_of(spec, '<c-b>')[2]())
      scrolled = true
      assert.is_nil(key_of(spec, '<c-f>')[2]())
      assert.is_nil(key_of(spec, '<c-b>')[2]())
      assert.same({ 4, -4, 4, -4 }, by)
    end)

    it('clears the messages Lazy left while installing', function()
      local setup_opts
      stub(package.loaded, 'noice', {
        setup = function(o) setup_opts = o end,
      })
      local spec = spec_of('folke/noice.nvim')
      vim.api.nvim_echo({ { 'dy-layout-kept' } }, true, {})
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'text' }))
      spec.config(nil, spec.opts)
      assert.equals(spec.opts, setup_opts)
      assert.is_truthy(
        vim.fn.execute('messages'):find('dy-layout-kept', 1, true)
      )

      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'lazy' }))
      spec.config(nil, spec.opts)
      assert.is_nil(vim.fn.execute('messages'):find('dy-layout-kept', 1, true))
    end)
  end)

  describe('edgy', function()
    it('toggles and selects from its keys', function()
      local calls = {}
      stub(package.loaded, 'edgy', {
        toggle = function() table.insert(calls, 'toggle') end,
        select = function() table.insert(calls, 'select') end,
      })
      local spec = spec_of('folke/edgy.nvim')
      key_of(spec, '<leader>ue')[2]()
      key_of(spec, '<leader>uE')[2]()
      assert.same({ 'toggle', 'select' }, calls)
    end)

    it('docks only split windows, never floats', function()
      local opts = spec_of('folke/edgy.nvim').opts()
      local win = vim.api.nvim_get_current_win()
      local float = vim.api.nvim_open_win(h.buffer({}), false, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 5,
        height = 2,
      })
      for _, ft in ipairs({ 'toggleterm', 'noice' }) do
        local panel
        for _, entry in ipairs(opts.bottom) do
          if type(entry) == 'table' and entry.ft == ft then panel = entry end
        end
        assert.is_true(panel.filter(nil, win), ft)
        assert.is_false(panel.filter(nil, float), ft)
      end
      vim.api.nvim_win_close(float, true)
    end)

    it('docks a help window, not a help file being edited', function()
      local opts = spec_of('folke/edgy.nvim').opts()
      local help
      for _, entry in ipairs(opts.bottom) do
        if type(entry) == 'table' and entry.ft == 'help' then help = entry end
      end
      local bufnr = h.buffer({})
      assert.is_false(help.filter(bufnr))
      vim.bo[bufnr].buftype = 'help'
      assert.is_true(help.filter(bufnr))
    end)

    it('resizes a panel from its keys', function()
      local opts = spec_of('folke/edgy.nvim').opts()
      local resized = {}
      local win = {
        resize = function(_, dim, n) table.insert(resized, dim .. n) end,
      }
      opts.keys['<c-Right>'](win)
      opts.keys['<c-Left>'](win)
      opts.keys['<c-Up>'](win)
      opts.keys['<c-Down>'](win)
      assert.same({ 'width2', 'width-2', 'height2', 'height-2' }, resized)
    end)

    it(
      'docks Trouble and Snacks terminals on the edge they split at',
      function()
        local opts = spec_of('folke/edgy.nvim').opts()
        ---@param pos string
        ---@param ft string
        local function panel(pos, ft)
          for _, entry in ipairs(opts[pos]) do
            if type(entry) == 'table' and entry.ft == ft then return entry end
          end
          error('no ' .. ft .. ' panel at ' .. pos)
        end
        local win = vim.api.nvim_get_current_win()
        for _, pos in ipairs({ 'top', 'bottom', 'left', 'right' }) do
          local trouble, terminal =
            panel(pos, 'trouble'), panel(pos, 'snacks_terminal')
          -- Neither window kind yet
          vim.w[win].trouble = nil
          vim.w[win].snacks_win = nil
          vim.w[win].trouble_preview = nil
          assert.is_falsy(trouble.filter(nil, win))
          assert.is_falsy(terminal.filter(nil, win))

          vim.w[win].trouble =
            { position = pos, type = 'split', relative = 'editor' }
          assert.is_true(trouble.filter(nil, win))
          vim.w[win].trouble =
            { position = pos, type = 'float', relative = 'editor' }
          assert.is_false(trouble.filter(nil, win))
          vim.w[win].trouble =
            { position = pos, type = 'split', relative = 'editor' }
          vim.w[win].trouble_preview = true
          assert.is_false(trouble.filter(nil, win))
          vim.w[win].trouble_preview = nil

          vim.w[win].snacks_win = { position = pos, relative = 'editor' }
          assert.is_true(terminal.filter(nil, win))
          vim.w[win].snacks_win = { position = pos, relative = 'win' }
          assert.is_false(terminal.filter(nil, win))
        end
        vim.w[win].trouble = nil
        vim.w[win].snacks_win = nil
      end
    )
  end)

  describe('bufferline offset', function()
    local Offset, old, layout

    before_each(function()
      old = { left = '', left_size = 0, right = '', right_size = 0 }
      Offset = { get = function() return old end }
      stub(package.loaded, 'bufferline.offset', Offset)
      stub(package.loaded, 'edgy', nil)
      layout = {
        left = { bounds = { width = 30 }, wins = {} },
        right = { bounds = { width = 20 }, wins = {} },
      }
      stub(package.loaded, 'edgy.config', { layout = layout })
    end)

    it('wraps the offset once', function()
      local get = Offset.get
      spec_of('akinsho/bufferline.nvim').opts()
      assert.is_true(Offset.edgy)
      assert.is_not.equals(get, Offset.get)
      local wrapped = Offset.get
      spec_of('akinsho/bufferline.nvim').opts()
      assert.equals(wrapped, Offset.get)
    end)

    it('leaves the offset alone until edgy loads', function()
      spec_of('akinsho/bufferline.nvim').opts()
      assert.equals(old, Offset.get())
      stub(package.loaded, 'edgy', {})
      -- Loaded, with no sidebar open
      assert.equals(old, Offset.get())
    end)

    it('leaves room for the sidebars edgy shows', function()
      spec_of('akinsho/bufferline.nvim').opts()
      stub(package.loaded, 'edgy', {})
      layout.left.wins = { 1 }
      local ret = Offset.get()
      assert.equals(30, ret.left_size)
      assert.equals(0, ret.right_size)
      assert.equals(30, ret.total_size)
      assert.is_truthy(ret.left:find(' Sidebar', 1, true))
      assert.is_truthy(ret.left:find('│%%%*$'))
      assert.equals('', ret.right)

      layout.right.wins = { 2 }
      ret = Offset.get()
      assert.equals(50, ret.total_size)
      assert.is_truthy(ret.right:find('^%%#BufferLineOffsetSeparator#│'))

      -- An offset bufferline computed itself wins over the placeholder
      old.right, old.right_size = 'explorer', 25
      ret = Offset.get()
      assert.equals('explorer', ret.right)
      assert.equals(25, ret.right_size)
      assert.equals(55, ret.total_size)
    end)
  end)
end)
