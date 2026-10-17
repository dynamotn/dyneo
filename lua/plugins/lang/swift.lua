local language = require('config.languages').swift

return vim.list_contains(DyNeo.enabled_languages, 'swift')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            sourcekit = {
              -- a build server description (what `xcode-build-server` writes
              -- for an Xcode project) or a package manifest marks the root of
              -- a Swift project
              root_markers = {
                'buildServer.json',
                'Package.swift',
                '.git',
              },
            },
          },
        },
      },
      {
        -- Debug adapters & configurations: a SwiftPM or `swiftc` binary,
        -- through the same `codelldb` the C family uses
        'mfussenegger/nvim-dap',
        optional = true,
        opts = function()
          local dap_util = require('util.dap')
          dap_util.codelldb_adapter()
          require('dap').configurations.swift =
            dap_util.codelldb_configurations('.build/debug/')
        end,
      },
      {
        -- The configurations above are the ones; mason-nvim-dap would list its
        -- `LLDB:` ones a second time beside them
        'jay-babu/mason-nvim-dap.nvim',
        optional = true,
        opts = { handlers = { codelldb = function() end } },
      },
      {
        -- Build, run and test an Xcode project without leaving the editor
        'wojciech-kulik/xcodebuild.nvim',
        -- Xcode, its simulators and devices are macOS only
        cond = vim.fn.has('mac') == 1,
        ft = language.filetypes,
        cmd = { 'XcodebuildPicker', 'XcodebuildBuild', 'XcodebuildTest' },
        dependencies = {
          'MunifTanjim/nui.nvim',
          -- the plugin needs a picker; this config already has this one
          'folke/snacks.nvim',
        },
        opts = {
          code_coverage = { enabled = true },
        },
        keys = {
          {
            '<localleader>x',
            '<cmd>XcodebuildPicker<cr>',
            ft = language.filetypes,
            desc = 'Xcodebuild actions',
          },
          {
            '<localleader>xb',
            '<cmd>XcodebuildBuild<cr>',
            ft = language.filetypes,
            desc = 'Build project',
          },
          {
            '<localleader>xr',
            '<cmd>XcodebuildBuildRun<cr>',
            ft = language.filetypes,
            desc = 'Build and run project',
          },
          {
            '<localleader>xt',
            '<cmd>XcodebuildTest<cr>',
            ft = language.filetypes,
            desc = 'Run tests',
          },
          {
            '<localleader>xT',
            '<cmd>XcodebuildTestClass<cr>',
            ft = language.filetypes,
            desc = 'Run this test class',
          },
          {
            '<localleader>xd',
            '<cmd>XcodebuildSelectDevice<cr>',
            ft = language.filetypes,
            desc = 'Select device',
          },
          {
            '<localleader>xc',
            '<cmd>XcodebuildToggleCodeCoverage<cr>',
            ft = language.filetypes,
            desc = 'Toggle code coverage',
          },
          {
            '<localleader>xl',
            '<cmd>XcodebuildToggleLogs<cr>',
            ft = language.filetypes,
            desc = 'Toggle logs',
          },
        },
      },
    }
  or {}
