local language = require('config.languages').lua
local cmp_util = require('util.cmp')

return vim.list_contains(DyNeo.enabled_languages, 'lua')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            lua_ls = {
              settings = {
                Lua = {
                  workspace = {
                    checkThirdParty = true,
                  },
                  codeLens = {
                    enable = true,
                  },
                  completion = {
                    callSnippet = 'Replace',
                  },
                  doc = {
                    privateName = { '^_' },
                  },
                  hint = {
                    enable = true,
                    setType = false,
                    paramType = true,
                    paramName = 'Disable',
                    semicolon = 'Disable',
                    arrayIndex = 'Disable',
                  },
                },
              },
            },
            harper_ls = {},
          },
        },
      },
      {
        -- Nvim LSP
        'folke/lazydev.nvim',
        ft = language.filetypes,
        cmd = 'LazyDev',
        init = function()
          DyNeo.completion_sources =
            vim.tbl_extend('force', DyNeo.completion_sources, {
              lazydev = '「VIM」',
            })
        end,
        opts = {
          library = {
            { path = '${3rd}/luv/library', words = { 'vim%.uv' } },
            { path = 'snacks.nvim', words = { 'Snacks' } },
            { path = 'nvim-lspconfig', words = { 'lspconfig.settings' } },
            { path = 'dial.nvim' },
            { path = 'nvim-autopairs' },
            { path = 'nvim-treesitter' },
          },
        },
      },
      {
        -- Test adapter, finding a project's `tests/minimal_init.lua` itself
        'nvim-neotest/neotest',
        dependencies = {
          'nvim-neotest/neotest-plenary',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-plenary'] = {},
          },
        },
      },
      {
        -- Debug adapter
        'jbyuki/one-small-step-for-vimkind',
        keys = {
          {
            '<leader>dn',
            function() require('osv').launch({ port = 8086 }) end,
            ft = language.filetypes,
            desc = 'Launch debug Neovim',
          },
        },
      },
      {
        -- Debug configurations
        --
        -- Registered when nvim-dap loads rather than when a Lua file opens:
        -- loading on `ft` pulled in nvim-dap and every adapter hanging off it
        -- on each Lua buffer, a debugger that is rarely used. `osv` itself is
        -- only required once a session starts.
        'mfussenegger/nvim-dap',
        opts = function()
          local dap = require('dap')
          dap.adapters.nlua = function(callback, conf)
            local adapter = {
              type = 'server',
              host = conf.host or '127.0.0.1',
              port = conf.port or 8086,
            }
            callback(adapter)
          end
          -- osv dropped `run_this`, which started a second Neovim on the
          -- file; `<leader>dn` launches the server to attach to instead
          dap.configurations.lua = {
            {
              type = 'nlua',
              request = 'attach',
              name = 'Attach to running Neovim instance (port = 8086)',
              port = 8086,
            },
          }
        end,
      },
      {
        -- Completion for Nvim LSP
        'blink.cmp',
        opts = {
          sources = {
            per_filetype = {
              lua = cmp_util.sources('lua'),
            },
            providers = {
              lazydev = {
                name = 'lazydev',
                module = 'lazydev.integrations.blink',
                score_offset = 100,
              },
            },
          },
        },
      },
    }
  or {}
