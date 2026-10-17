local language = require('config.languages').zig

return vim.list_contains(DyNeo.enabled_languages, 'zig')
    and {
      {
        -- Debug adapters & configurations: what `zig build` leaves in
        -- `zig-out/bin`, through the same `codelldb` the C family uses
        'mfussenegger/nvim-dap',
        optional = true,
        opts = function()
          local dap_util = require('util.dap')
          dap_util.codelldb_adapter()
          require('dap').configurations.zig =
            dap_util.codelldb_configurations('zig-out/bin/')
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
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'lawrence-laz/neotest-zig',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-zig'] = {},
          },
        },
      },
    }
  or {}
