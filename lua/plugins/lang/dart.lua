local language = require('config.languages').dart

-- flutter-tools finds its SDK through `flutter` alone: with just `dart` it
-- hands its debugger setup no paths and fails on the first Dart file
local function has_flutter() return vim.fn.executable('flutter') == 1 end

return vim.list_contains(DyNeo.enabled_languages, 'dart')
    and {
      {
        -- Flutter toolbox: runner, devices, outline, and the Dart LSP
        'akinsho/flutter-tools.nvim',
        ft = language.filetypes,
        cond = has_flutter,
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
        -- lspconfig from starting a second one; with only the Dart SDK,
        -- lspconfig starts it. The entry in `config.languages` is what
        -- installs and documents the server.
        'neovim/nvim-lspconfig',
        opts = {
          setup = {
            dartls = has_flutter,
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
