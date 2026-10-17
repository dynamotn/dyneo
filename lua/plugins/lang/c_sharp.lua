local language = require('config.languages').c_sharp

return vim.list_contains(DyNeo.enabled_languages, 'c_sharp')
    and {
      {
        -- Extended LSP
        'Hoffs/omnisharp-extended-lsp.nvim',
        ft = language.filetypes,
      },
      {
        -- Config for LSP
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            omnisharp = {
              -- `vim.lsp.buf.definition` no longer goes through a handler
              -- since 0.11, so the decompiled sources come from this key
              keys = {
                {
                  'gd',
                  function() require('omnisharp_extended').lsp_definitions() end,
                  desc = 'Goto Definition',
                },
              },
              -- The server's own settings; the snake_case options of the
              -- old lspconfig framework are read by nothing any more
              settings = {
                FormattingOptions = { OrganizeImports = true },
                RoslynExtensionsOptions = {
                  EnableAnalyzersSupport = true,
                  EnableImportCompletion = true,
                },
              },
            },
          },
        },
      },
      {
        -- Debug adapters & configurations
        'mfussenegger/nvim-dap',
        opts = function()
          local dap = require('dap')
          if not dap.adapters['netcoredbg'] then
            require('dap').adapters['netcoredbg'] = {
              type = 'executable',
              -- Looked up on `$PATH` as a session starts, so a netcoredbg
              -- Mason installs after startup is found too
              command = 'netcoredbg',
              args = { '--interpreter=vscode' },
              options = {
                detached = false,
              },
            }
          end
          for _, filetype in ipairs(language.filetypes) do
            if not dap.configurations[filetype] then
              dap.configurations[filetype] = {
                {
                  type = 'netcoredbg',
                  name = 'Launch file',
                  request = 'launch',
                  ---@diagnostic disable-next-line: redundant-parameter
                  program = function()
                    return vim.fn.input(
                      'Path to dll: ',
                      vim.fn.getcwd() .. '/',
                      'file'
                    )
                  end,
                  cwd = '${workspaceFolder}',
                },
              }
            end
          end
        end,
      },
      {
        -- netcoredbg is set up above; mason-nvim-dap would add a `coreclr`
        -- adapter and its `NetCoreDbg:` configurations beside it
        'jay-babu/mason-nvim-dap.nvim',
        optional = true,
        opts = { handlers = { coreclr = function() end } },
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'Nsidorenco/neotest-vstest',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-vstest'] = {},
          },
        },
      },
    }
  or {}
