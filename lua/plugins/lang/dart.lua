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
        config = function(_, opts)
          require('flutter-tools').setup(opts)
          -- Its ftplugin starts dartls through `attach`, with no setting to
          -- turn a buffer down: wrapped, so a buffer under a directory still
          -- held untrusted gets no server, whose analyzer plugins are the
          -- project's code. The original is kept, so configuring again
          -- (`:Lazy reload`) does not wrap the wrapper.
          local lsp = require('flutter-tools.lsp')
          local attach = lsp.dy_attach or lsp.attach
          lsp.dy_attach = attach
          lsp.attach = function(...)
            if require('util.untrusted').held(0) then return end
            return attach(...)
          end
          -- It runs `flutter pub get` when a pubspec is saved, which runs
          -- the project's build hooks. Its autocmd, `:FlutterPubGet` and its
          -- menu all look `pub_get` up on the module (the command when the
          -- first Dart buffer enters), so wrapping the field covers them.
          local commands = require('flutter-tools.commands')
          local pub_get = commands.dy_pub_get or commands.pub_get
          commands.dy_pub_get = pub_get
          commands.pub_get = function(...)
            if require('util.untrusted').held(0) then return end
            return pub_get(...)
          end
          require('util.untrusted').on_release('flutter-tools', function(bufnr)
            if
              vim.list_contains(language.filetypes, vim.bo[bufnr].filetype)
            then
              -- It attaches to the current buffer
              vim.api.nvim_buf_call(bufnr, function() lsp.attach() end)
            end
          end)
        end,
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
