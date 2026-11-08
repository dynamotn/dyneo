local language = require('config.languages').c_sharp

return vim.list_contains(DyNeo.enabled_languages, 'c_sharp')
    and {
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
