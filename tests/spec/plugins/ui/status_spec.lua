local h = require('helpers')

local file = h.root .. '/lua/plugins/ui/status.lua'

--- Every spec of `name` in the file, in order: lualine has two
---@param name string
---@return table[]
local function specs_of(name)
  local found = {}
  for _, spec in ipairs(dofile(file)) do
    if spec[1] == name then table.insert(found, spec) end
  end
  return found
end

--- The `keys` entry of `spec` mapped to `lhs`
---@param spec table
---@param lhs string
---@return table
local function key_of(spec, lhs)
  for _, key in ipairs(spec.keys) do
    if key[1] == lhs then return key end
  end
  error('no key ' .. lhs)
end

describe('plugins.ui.status', function()
  local restores, snacks, toggles

  ---@generic T
  ---@param tbl T
  ---@param key any
  ---@param value any
  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    h.globals()
    restores = {}
    toggles = {}
    snacks = {
      util = {
        color = function(group) return 'color:' .. group end,
      },
      profiler = {
        status = function() return { 'profiler' } end,
      },
      toggle = function(opts)
        table.insert(toggles, opts)
        return {
          map = function(_, lhs) opts.mapped = lhs end,
        }
      end,
    }
    stub(_G, 'Snacks', snacks)
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  describe('lualine', function()
    local laststatus, statusline

    before_each(function()
      laststatus, statusline = vim.o.laststatus, vim.o.statusline
      stub(package.loaded, 'lualine_require', { require = nil })
      stub(package.loaded, 'trouble', nil)
      stub(package.loaded, 'noice', nil)
      stub(package.loaded, 'dap', nil)
    end)
    after_each(function()
      vim.o.laststatus, vim.o.statusline = laststatus, statusline
      vim.g.lualine_laststatus = nil
      vim.g.trouble_lualine = nil
    end)

    it('shows an empty status line until it loads, given files', function()
      stub(vim.fn, 'argc', function() return 2 end)
      vim.o.laststatus = 2
      specs_of('nvim-lualine/lualine.nvim')[1].init()
      assert.equals(2, vim.g.lualine_laststatus)
      assert.equals(' ', vim.o.statusline)
      assert.equals(2, vim.o.laststatus)
    end)

    it('shows none at all on the dashboard', function()
      stub(vim.fn, 'argc', function() return 0 end)
      vim.o.laststatus = 3
      specs_of('nvim-lualine/lualine.nvim')[1].init()
      assert.equals(3, vim.g.lualine_laststatus)
      assert.equals(0, vim.o.laststatus)
    end)

    it('puts the status line back and skips the require wrapper', function()
      vim.g.lualine_laststatus = 3
      vim.o.laststatus = 0
      local opts = specs_of('nvim-lualine/lualine.nvim')[1].opts()
      assert.equals(3, vim.o.laststatus)
      assert.is_true(opts.options.globalstatus)
      assert.equals(require, package.loaded.lualine_require.require)
      assert.same({ 'lazy' }, opts.extensions)
      -- No Trouble symbols without `vim.g.trouble_lualine`
      assert.equals(4, #opts.sections.lualine_c)
    end)

    it('reports noice, dap and lazy.nvim only when they say so', function()
      vim.g.lualine_laststatus = 2
      local x =
        specs_of('nvim-lualine/lualine.nvim')[1].opts().sections.lualine_x
      local command, mode, dap, lazy = x[2], x[3], x[4], x[5]

      -- Not loaded: nothing to show
      assert.is_falsy(command.cond())
      assert.is_falsy(mode.cond())
      assert.is_falsy(dap.cond())

      stub(package.loaded, 'noice', {
        api = {
          status = {
            command = {
              has = function() return true end,
              get = function() return 'rec @q' end,
            },
            mode = {
              has = function() return false end,
              get = function() return '-- INSERT --' end,
            },
          },
        },
      })
      assert.is_true(command.cond())
      assert.equals('rec @q', command[1]())
      assert.same({ fg = 'color:Statement' }, command.color())
      assert.is_false(mode.cond())
      assert.equals('-- INSERT --', mode[1]())
      assert.same({ fg = 'color:Constant' }, mode.color())

      stub(package.loaded, 'dap', { status = function() return '' end })
      assert.is_false(dap.cond())
      stub(package.loaded, 'dap', { status = function() return 'Running' end })
      assert.is_true(dap.cond())
      assert.is_truthy(dap[1]():find(' Running', 1, true))
      assert.same({ fg = 'color:Debug' }, dap.color())

      assert.equals(require('lazy.status').updates, lazy[1])
      assert.equals(require('lazy.status').has_updates, lazy.cond)
      assert.same({ fg = 'color:Special' }, lazy.color())
    end)

    it('takes the diff counts from gitsigns', function()
      vim.g.lualine_laststatus = 2
      local x =
        specs_of('nvim-lualine/lualine.nvim')[1].opts().sections.lualine_x
      local diff = x[6]
      assert.equals('diff', diff[1])
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      assert.is_nil(diff.source())
      vim.b[bufnr].gitsigns_status_dict =
        { added = 1, changed = 2, removed = 3 }
      assert.same({ added = 1, modified = 2, removed = 3 }, diff.source())
    end)

    it('adds the symbols around the cursor from Trouble', function()
      vim.g.lualine_laststatus = 2
      vim.g.trouble_lualine = true
      local has = {}
      stub(
        require('util.plugin'),
        'has',
        function(name) return has[name] == true end
      )
      -- Trouble not part of the configuration: no component
      local opts = specs_of('nvim-lualine/lualine.nvim')[1].opts()
      assert.equals(4, #opts.sections.lualine_c)

      has['trouble.nvim'] = true
      local statusline_opts
      local present = true
      stub(package.loaded, 'trouble', {
        statusline = function(o)
          statusline_opts = o
          return {
            get = function() return 'symbols' end,
            has = function() return present end,
          }
        end,
      })
      opts = specs_of('nvim-lualine/lualine.nvim')[1].opts()
      local symbols = opts.sections.lualine_c[5]
      assert.equals('symbols', statusline_opts.mode)
      assert.equals('symbols', symbols[1]())
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      assert.is_true(symbols.cond())
      present = false
      assert.is_false(symbols.cond())
      present = true
      -- A buffer turns them off on its own
      vim.b[bufnr].trouble_lualine = false
      assert.is_false(symbols.cond())
    end)

    it('adds its own sections on top', function()
      local opts = { sections = {} }
      specs_of('nvim-lualine/lualine.nvim')[2].opts(nil, opts)
      assert.equals('progress', opts.sections.lualine_z[1][1])
      assert.equals('location', opts.sections.lualine_z[2][1])
      assert.equals('Avante', opts.special_filetypes.AvanteInput)

      local treesitter, lsp, tools = unpack(opts.sections.lualine_y)
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      assert.equals('', treesitter[1]())
      local active = vim.treesitter.highlighter.active
      stub(active, bufnr, {})
      assert.equals(
        require('config.defaults').icons.treesitter.core,
        treesitter[1]()
      )
      assert.same({ fg = 'color:String' }, treesitter.color())

      local called = {}
      stub(package.loaded, 'util.statusline', {
        lsp_status = function(icon) return 'lsp:' .. icon end,
        tools_status = function(icon) return 'tools:' .. icon end,
        pick_lsp = function() called.lsp = true end,
        pick_tools = function() called.tools = true end,
      })
      local icons = require('config.defaults').icons
      assert.equals('lsp:' .. icons.lsp, lsp[1]())
      assert.equals('tools:' .. icons.null_ls, tools[1]())
      assert.same({ fg = 'color:Label', gui = 'bold' }, lsp.color())
      assert.same({ fg = 'color:Statement', gui = 'bold' }, tools.color())
      lsp.on_click()
      tools.on_click()
      assert.same({ lsp = true, tools = true }, called)
    end)

    it('picks the servers and tools of the buffer from its keys', function()
      local called = {}
      stub(package.loaded, 'util.statusline', {
        pick_lsp = function() called.lsp = true end,
        pick_tools = function() called.tools = true end,
      })
      local spec = specs_of('nvim-lualine/lualine.nvim')[2]
      key_of(spec, '<leader>cL')[2]()
      key_of(spec, '<leader>cT')[2]()
      assert.same({ lsp = true, tools = true }, called)
    end)

    it('sets up one extension per special filetype', function()
      local setup_opts, statusline_setup
      stub(package.loaded, 'util.statusline', {
        setup = function() statusline_setup = true end,
      })
      stub(package.loaded, 'lualine', {
        setup = function(o) setup_opts = o end,
      })
      stub(package.loaded, 'tools.ai', {
        status = function() return nil end,
      })
      local opts = {
        extensions = { 'lazy' },
        special_filetypes = { help = 'Help Guide', Avante = 'Avante' },
      }
      specs_of('nvim-lualine/lualine.nvim')[2].config(nil, opts)
      assert.is_true(statusline_setup)
      assert.equals(opts, setup_opts)
      assert.equals(3, #opts.extensions)
      local by_ft = {}
      for _, extension in ipairs(opts.extensions) do
        if type(extension) == 'table' then
          by_ft[extension.filetypes[1]] = extension
        end
      end
      assert.equals('Help Guide', by_ft.help.sections.lualine_a[1]())
      assert.is_nil(by_ft.help.sections.lualine_b)
      assert.equals('Avante', by_ft.Avante.sections.lualine_a[1]())
      -- The provider Avante talks to, or nothing while it has none
      assert.equals('', by_ft.Avante.sections.lualine_b[1]())
      package.loaded['tools.ai'].status = function() return 'claude' end
      assert.equals('claude', by_ft.Avante.sections.lualine_b[1]())
    end)
  end)

  describe('bufferline', function()
    local spec

    before_each(function() spec = specs_of('akinsho/bufferline.nvim')[1] end)

    it('closes a tab by its handle', function()
      vim.cmd.tabnew()
      local tabpage = vim.api.nvim_get_current_tabpage()
      assert.is_true(#vim.api.nvim_list_tabpages() > 1)
      spec.opts.options.close_command(tabpage)
      assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
      -- A handle already gone is nothing to close
      spec.opts.options.right_mouse_command(tabpage)
      assert.equals(1, #vim.api.nvim_list_tabpages())
    end)

    it('shows the error and warning counts', function()
      local icons = require('config.defaults').icons.diagnostics
      local indicator = spec.opts.options.diagnostics_indicator
      assert.equals(
        vim.trim(icons.Error .. '2 ' .. icons.Warn .. '1'),
        indicator(nil, nil, { error = 2, warning = 1 })
      )
      assert.equals(
        vim.trim(icons.Warn .. '3'),
        indicator(nil, nil, { warning = 3 })
      )
      assert.equals('', indicator(nil, nil, {}))
    end)

    it('takes icons and numbers from the configuration', function()
      local icons = require('config.defaults').icons.ft
      local options = spec.opts.options
      assert.equals(
        icons.Avante,
        options.get_element_icon({ filetype = 'Avante' })
      )
      assert.is_nil(options.get_element_icon({ filetype = 'lua' }))
      assert.equals(
        '3',
        options.numbers({ id = 3, raise = function(id) return id end })
      )
    end)

    it('redraws once a buffer comes or goes', function()
      local setup_opts
      stub(package.loaded, 'bufferline', {
        setup = function(o) setup_opts = o end,
      })
      local redraws = 0
      stub(_G, 'nvim_bufferline', function() redraws = redraws + 1 end)
      spec.config(nil, spec.opts)
      assert.equals(spec.opts, setup_opts)
      h.buffer({})
      vim.wait(100, function() return redraws > 0 end)
      assert.equals(1, redraws)
      -- Without the plugin's redraw function the autocmd stays quiet
      stub(_G, 'nvim_bufferline', nil)
      h.buffer({})
      vim.wait(50)
      assert.equals(1, redraws)
      vim.api.nvim_del_augroup_by_name('dyneo_bufferline')
    end)
  end)

  describe('satellite', function()
    it('toggles the scrollbar', function()
      local spec = specs_of('lewis6991/satellite.nvim')[1]
      local setup_opts
      stub(package.loaded, 'satellite', {
        setup = function(o) setup_opts = o end,
      })
      local commands = {}
      for _, name in ipairs({ 'SatelliteEnable', 'SatelliteDisable' }) do
        vim.api.nvim_create_user_command(
          name,
          function() table.insert(commands, name) end,
          {}
        )
      end
      spec.config(nil, spec.opts)
      assert.equals(spec.opts, setup_opts)
      local toggle = toggles[1]
      assert.equals('Scrollbar', toggle.name)
      assert.equals('<leader>uB', toggle.mapped)
      assert.is_true(toggle.get())
      toggle.set(false)
      assert.is_false(toggle.get())
      toggle.set(true)
      assert.is_true(toggle.get())
      assert.same({ 'SatelliteDisable', 'SatelliteEnable' }, commands)
      for _, name in ipairs({ 'SatelliteEnable', 'SatelliteDisable' }) do
        vim.api.nvim_del_user_command(name)
      end
    end)
  end)

  describe('dropbar', function()
    it('picks a symbol of the winbar', function()
      local picked = false
      stub(package.loaded, 'dropbar.api', {
        pick = function() picked = true end,
      })
      local spec = specs_of('Bekaboo/dropbar.nvim')[1]
      key_of(spec, '<leader>;')[2]()
      assert.is_true(picked)
      assert.equals(
        require('config.defaults').icons.kinds,
        spec.opts.icons.kinds.symbols
      )
    end)
  end)
end)
