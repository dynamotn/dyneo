local language = require('config.languages').dart

return vim.list_contains(DyNeo.enabled_languages, 'dart')
    and {
      {
        -- Flutter toolbox: runner, devices, outline, and the Dart LSP
        'akinsho/flutter-tools.nvim',
        ft = language.filetypes,
        -- Without an SDK it hands its debugger setup no paths and fails on
        -- the first Dart file, and there is no `dartls` for it to start.
        cond = function()
          return vim.fn.executable('flutter') == 1
            or vim.fn.executable('dart') == 1
        end,
        dependencies = { 'nvim-lua/plenary.nvim' },
        -- stylua: ignore
        keys = {
          { '<localleader>r', '<cmd>FlutterRun<cr>', desc = 'Flutter Run', ft = language.filetypes },
          { '<localleader>R', '<cmd>FlutterRestart<cr>', desc = 'Flutter Restart', ft = language.filetypes },
          { '<localleader>d', '<cmd>FlutterDevices<cr>', desc = 'Flutter Devices', ft = language.filetypes },
          { '<localleader>q', '<cmd>FlutterQuit<cr>', desc = 'Flutter Quit', ft = language.filetypes },
        },
        opts = {
          -- `:FlutterRun` through nvim-dap, so breakpoints hold
          debugger = { enabled = true },
        },
      },
      {
        -- `flutter-tools` starts `dartls` with its own settings, so keep
        -- lspconfig from starting a second one; the entry in
        -- `config.languages` is what installs and documents the server.
        'neovim/nvim-lspconfig',
        opts = {
          setup = {
            dartls = function() return true end,
          },
        },
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'sidlatau/neotest-dart',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-dart'] = {},
          },
        },
      },
    }
  or {}
