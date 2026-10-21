--- Close the tab of a bufferline element, by its tabpage handle
---@param tabpage integer
local function close_tab(tabpage)
  if not vim.api.nvim_tabpage_is_valid(tabpage) then return end
  pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tabpage))
end

return {
  {
    -- Status line: mode, branch, root, diagnostics, path, then the state of
    -- noice, dap, lazy.nvim and the git diff
    'nvim-lualine/lualine.nvim',
    event = 'VeryLazy',
    init = function()
      vim.g.lualine_laststatus = vim.o.laststatus
      if vim.fn.argc(-1) > 0 then
        -- An empty status line until lualine loads
        vim.o.statusline = ' '
      else
        -- None at all on the dashboard
        vim.o.laststatus = 0
      end
    end,
    opts = function()
      -- lualine's own `require` wrapper only slows it down
      local lualine_require = require('lualine_require')
      lualine_require.require = require

      local icons = require('config.defaults').icons
      local Lualine = require('util.lualine')

      vim.o.laststatus = vim.g.lualine_laststatus

      local opts = {
        options = {
          theme = 'auto',
          globalstatus = vim.o.laststatus == 3,
          disabled_filetypes = {
            statusline = {
              'dashboard',
              'alpha',
              'ministarter',
              'snacks_dashboard',
            },
          },
        },
        sections = {
          lualine_a = { 'mode' },
          lualine_b = {
            'branch',
            -- Who CODEOWNERS says owns the file: nothing where the
            -- repository has none. Read from a cache, not on each redraw
            {
              function() return require('tools.owners').statusline() end,
              icon = '󰀎',
            },
          },

          lualine_c = {
            Lualine.root_dir(),
            {
              'diagnostics',
              symbols = {
                error = icons.diagnostics.Error,
                warn = icons.diagnostics.Warn,
                info = icons.diagnostics.Info,
                hint = icons.diagnostics.Hint,
              },
            },
            {
              'filetype',
              icon_only = true,
              separator = '',
              padding = { left = 1, right = 0 },
            },
            { Lualine.pretty_path() },
          },
          lualine_x = {
            Snacks.profiler.status(),
            -- stylua: ignore
            {
              function() return require('noice').api.status.command.get() end,
              cond = function() return package.loaded['noice'] and require('noice').api.status.command.has() end,
              color = function() return { fg = Snacks.util.color('Statement') } end,
            },
            -- stylua: ignore
            {
              function() return require('noice').api.status.mode.get() end,
              cond = function() return package.loaded['noice'] and require('noice').api.status.mode.has() end,
              color = function() return { fg = Snacks.util.color('Constant') } end,
            },
            -- stylua: ignore
            {
              function() return '  ' .. require('dap').status() end,
              cond = function() return package.loaded['dap'] and require('dap').status() ~= '' end,
              color = function() return { fg = Snacks.util.color('Debug') } end,
            },
            -- stylua: ignore
            {
              require('lazy.status').updates,
              cond = require('lazy.status').has_updates,
              color = function() return { fg = Snacks.util.color('Special') } end,
            },
            {
              'diff',
              symbols = {
                added = icons.git.added,
                modified = icons.git.modified,
                removed = icons.git.removed,
              },
              source = function()
                local gitsigns = vim.b.gitsigns_status_dict
                if gitsigns then
                  return {
                    added = gitsigns.added,
                    modified = gitsigns.changed,
                    removed = gitsigns.removed,
                  }
                end
              end,
            },
          },
          -- `lualine_y` and `lualine_z` are the second spec's below
        },
        extensions = { 'lazy' },
      }

      -- Symbols around the cursor from Trouble, unless a buffer turns them
      -- off with `vim.b.trouble_lualine = false`
      if
        vim.g.trouble_lualine and require('util.plugin').has('trouble.nvim')
      then
        local trouble = require('trouble')
        local symbols = trouble.statusline({
          mode = 'symbols',
          groups = {},
          title = false,
          filter = { range = true },
          format = '{kind_icon}{symbol.name:Normal}',
          hl_group = 'lualine_c_normal',
        })
        table.insert(opts.sections.lualine_c, {
          symbols and symbols.get,
          cond = function()
            return vim.b.trouble_lualine ~= false and symbols.has()
          end,
        })
      end

      return opts
    end,
  },
  {
    -- My own sections, on top of the ones above
    'nvim-lualine/lualine.nvim',
    keys = {
      {
        '<leader>cL',
        function() require('util.statusline').pick_lsp() end,
        desc = 'Language servers of buffer',
      },
      {
        '<leader>cT',
        function() require('util.statusline').pick_tools() end,
        desc = 'Formatters and linters of buffer',
      },
    },
    opts = function(_, opts)
      local icons = require('config.defaults').icons

      opts.sections.lualine_z = {
        { 'progress', separator = '', padding = { left = 1, right = 0 } },
        { 'location', separator = '', padding = { left = 1, right = 0 } },
      }
      opts.sections.lualine_y = {
        {
          function()
            local b = vim.api.nvim_get_current_buf()
            if vim.treesitter.highlighter.active[b] ~= nil then
              return icons.treesitter.core
            end
            return ''
          end,
          color = function() return { fg = Snacks.util.color('String') } end,
        },
        {
          -- Counts only; a click lists every server with its state
          function() return require('util.statusline').lsp_status(icons.lsp) end,
          on_click = function() require('util.statusline').pick_lsp() end,
          color = function()
            return { fg = Snacks.util.color('Label'), gui = 'bold' }
          end,
        },
        {
          function()
            return require('util.statusline').tools_status(icons.null_ls)
          end,
          on_click = function() require('util.statusline').pick_tools() end,
          color = function()
            return { fg = Snacks.util.color('Statement'), gui = 'bold' }
          end,
        },
      }
      opts.special_filetypes = {
        help = 'Help Guide',
        terminal = 'Terminal',
        snacks_picker_list = 'Explorer',
        Avante = 'Avante',
        AvanteInput = 'Avante',
        AvanteSelectedFiles = 'Avante',
        AvanteSelectedCode = 'Avante',
        AvanteTodos = 'Avante',
      }
    end,
    config = function(_, opts)
      for filetype, name in pairs(opts.special_filetypes) do
        vim.list_extend(opts.extensions, {
          {
            filetypes = { filetype },
            sections = {
              lualine_a = {
                function() return name or 'N/A' end,
              },
              -- In Avante, the provider it is talking to
              lualine_b = name == 'Avante'
                  and {
                    function() return require('tools.ai').status() or '' end,
                  }
                or nil,
            },
          },
        })
      end
      require('util.statusline').setup()
      require('lualine').setup(opts)
    end,
  },
  {
    -- Buffer and tab line, showing tabs
    'akinsho/bufferline.nvim',
    event = 'VeryLazy',
    -- The line lists tabs (`mode = 'tabs'`), so its commands move between and
    -- close tabs: the buffer keys of `config.keymaps` are left to Neovim's
    -- own `:bnext` and `:bprevious`.
    keys = {
      { '[B', '<cmd>BufferLineMovePrev<cr>', desc = 'Move Tab Prev' },
      { ']B', '<cmd>BufferLineMoveNext<cr>', desc = 'Move Tab Next' },
      { '<leader><tab>p', '<cmd>BufferLinePick<cr>', desc = 'Pick Tab' },
    },
    opts = {
      options = {
        -- Handed a tabpage handle, which is not the number `:tabclose` takes
        close_command = close_tab,
        right_mouse_command = close_tab,
        diagnostics = 'nvim_lsp',
        always_show_bufferline = false,
        diagnostics_indicator = function(_, _, diag)
          local icons = require('config.defaults').icons.diagnostics
          local ret = (diag.error and icons.Error .. diag.error .. ' ' or '')
            .. (diag.warning and icons.Warn .. diag.warning or '')
          return vim.trim(ret)
        end,
        offsets = {
          {
            filetype = 'snacks_layout_box',
          },
          {
            -- Avante docks its own sidebar, outside edgy's offsets
            filetype = 'Avante',
            text = '󰚩 Avante',
            highlight = 'Directory',
            text_align = 'left',
          },
        },
        ---@param opts bufferline.IconFetcherOpts
        get_element_icon = function(opts)
          return (require('config.defaults').icons.ft or {})[opts.filetype]
        end,
        mode = 'tabs',
        numbers = function(number_opts)
          return string.format('%s', number_opts.raise(number_opts.id))
        end,
        show_buffer_close_icons = false,
        show_close_icon = false,
        separator_style = 'slant',
        sort_by = 'tabs',
      },
    },
    cond = not vim.g.started_by_firenvim,
    config = function(_, opts)
      require('bufferline').setup(opts)
      -- Redraw once a buffer comes or goes, which a restored session
      -- otherwise misses
      vim.api.nvim_create_autocmd({ 'BufAdd', 'BufDelete' }, {
        group = vim.api.nvim_create_augroup(
          'dyneo_bufferline',
          { clear = true }
        ),
        callback = function()
          vim.schedule(function() pcall(nvim_bufferline) end)
        end,
      })
    end,
  },
  {
    -- Scrollbar marking the cursor, search results, diagnostics, git hunks,
    -- marks and quickfix entries across the whole buffer
    'lewis6991/satellite.nvim',
    event = 'LazyFile',
    cond = not vim.g.started_by_firenvim,
    opts = {
      -- Side panels and pickers have nothing to scroll through worth marking
      excluded_filetypes = {
        'dap-view',
        'dap-repl',
        'Outline',
        'trouble',
        'qf',
        'snacks_dashboard',
        'snacks_picker_list',
        'snacks_picker_input',
        'snacks_terminal',
        'Avante',
        'AvanteInput',
        'AvanteSelectedFiles',
        'AvanteSelectedCode',
        'AvanteTodos',
        'lazy',
        'mason',
      },
      handlers = {
        -- `marks.nvim` sets the marks, with its own `m` mappings
        marks = { enable = true, show_builtins = false, key = 'm' },
      },
    },
    config = function(_, opts)
      require('satellite').setup(opts)
      local enabled = true
      Snacks.toggle({
        name = 'Scrollbar',
        get = function() return enabled end,
        set = function(state)
          enabled = state
          vim.cmd(state and 'SatelliteEnable' or 'SatelliteDisable')
        end,
      }):map('<leader>uB')
    end,
  },
  {
    -- Winbar to show context of current position
    'Bekaboo/dropbar.nvim',
    event = 'UIEnter',
    cond = not vim.g.started_by_firenvim,
    keys = {
      {
        '<leader>;',
        function() require('dropbar.api').pick() end,
        desc = 'Pick Winbar Symbol',
      },
    },
    opts = {
      icons = {
        kinds = {
          symbols = require('config.defaults').icons.kinds,
        },
      },
    },
  },
}
