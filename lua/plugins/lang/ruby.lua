local language = require('config.languages').ruby

return vim.list_contains(DyNeo.enabled_languages, 'ruby')
    and {
      {
        -- Debug adapters & configurations
        'mfussenegger/nvim-dap',
        -- Loaded with nvim-dap, not on `ft`: the adapter requires nvim-dap, so
        -- loading it with the filetype brought the whole debugger along on
        -- every buffer of the language.
        dependencies = {
          'suketa/nvim-dap-ruby',
          config = function() require('dap-ruby').setup() end,
        },
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        -- RSpec for `*_spec.rb`, Minitest for `*_test.rb`, Rails' default
        dependencies = {
          { 'olimorris/neotest-rspec', ft = language.filetypes },
          { 'zidhuss/neotest-minitest', ft = language.filetypes },
        },
        opts = {
          adapters = {
            ['neotest-rspec'] = {},
            ['neotest-minitest'] = {},
          },
        },
      },
    }
  or {}
