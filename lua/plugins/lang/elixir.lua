local language = require('config.languages').elixir

return vim.list_contains(DyNeo.enabled_languages, 'elixir')
    and {
      {
        -- Debug adapter & configurations. mason-nvim-dap maps `elixir` to the
        -- `elixir-ls` package but names its adapter `mix_task`, so its own
        -- handler finds nothing to set up; the adapter is registered here.
        'mfussenegger/nvim-dap',
        optional = true,
        opts = function()
          local dap = require('dap')
          dap.adapters.mix_task = {
            type = 'executable',
            command = 'elixir-ls-debugger',
            args = {},
          }
          local test = {
            type = 'mix_task',
            request = 'launch',
            task = 'test',
            -- Starts the application, as a Phoenix project's tests need
            startApps = true,
            projectDir = '${workspaceFolder}',
            requireFiles = {
              'test/**/test_helper.exs',
              'test/**/*_test.exs',
            },
          }
          dap.configurations.elixir = {
            vim.tbl_extend(
              'force',
              test,
              { name = 'mix test', taskArgs = { '--trace' } }
            ),
            vim.tbl_extend(
              'force',
              test,
              { name = 'mix test (file)', taskArgs = { '${file}', '--trace' } }
            ),
          }
        end,
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'jfpedroza/neotest-elixir',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-elixir'] = {},
          },
        },
      },
    }
  or {}
