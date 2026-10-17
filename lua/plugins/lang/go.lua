local language = require('config.languages').go

return vim.list_contains(DyNeo.enabled_languages, 'go')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            gopls = {
              settings = {
                gopls = {
                  gofumpt = true,
                  codelenses = {
                    generate = true,
                    regenerate_cgo = true,
                    run_govulncheck = true,
                    test = true,
                    tidy = true,
                    upgrade_dependency = true,
                    vendor = true,
                  },
                  hints = {
                    assignVariableTypes = true,
                    compositeLiteralFields = true,
                    compositeLiteralTypes = true,
                    constantValues = true,
                    functionTypeParameters = true,
                    parameterNames = true,
                    rangeVariableTypes = true,
                  },
                  analyses = {
                    nilness = true,
                    unusedparams = true,
                    unusedwrite = true,
                  },
                  usePlaceholders = true,
                  completeUnimported = true,
                  staticcheck = true,
                  directoryFilters = {
                    '-.git',
                    '-.vscode',
                    '-.idea',
                    '-.vscode-test',
                    '-node_modules',
                  },
                  semanticTokens = true,
                },
              },
            },
          },
          setup = {
            gopls = function(_, _)
              -- workaround for gopls not supporting semanticTokensProvider
              -- https://github.com/golang/go/issues/54531#issuecomment-1464982242
              Snacks.util.lsp.on({ name = 'gopls' }, function(_, client)
                if not client.server_capabilities.semanticTokensProvider then
                  -- The capabilities the client sent, merged; `config` only
                  -- holds what was configured, which may have no
                  -- `textDocument` at all
                  local semantic = vim.tbl_get(
                    client.capabilities,
                    'textDocument',
                    'semanticTokens'
                  )
                  if not semantic then return end
                  client.server_capabilities.semanticTokensProvider = {
                    full = true,
                    legend = {
                      tokenTypes = semantic.tokenTypes,
                      tokenModifiers = semantic.tokenModifiers,
                    },
                    range = true,
                  }
                end
              end)
              -- end workaround
            end,
          },
        },
      },
      {
        -- Debug adapters & configurations
        'mfussenegger/nvim-dap',
        -- Loaded with nvim-dap, not on `ft`: the adapter requires nvim-dap, so
        -- loading it with the filetype brought the whole debugger along on
        -- every buffer of the language.
        dependencies = {
          'leoluz/nvim-dap-go',
          opts = {},
        },
      },
      {
        -- nvim-dap-go brings the adapter and its configurations; mason-nvim-dap
        -- would add four `Delve:` ones of its own beside them
        'jay-babu/mason-nvim-dap.nvim',
        optional = true,
        opts = { handlers = { delve = function() end } },
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'fredrikaverpil/neotest-golang',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-golang'] = {
              dap_mode = 'dap-go',
            },
          },
        },
      },
      {
        -- Filetype icons
        'nvim-mini/mini.icons',
        opts = {
          file = {
            ['.go-version'] = { glyph = ' ', hl = 'MiniIconsBlue' },
          },
        },
      },
    }
  or {}
