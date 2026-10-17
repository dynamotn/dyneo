local language = require('config.languages').php

return vim.list_contains(DyNeo.enabled_languages, 'php')
    and {
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'olimorris/neotest-phpunit',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-phpunit'] = {},
          },
        },
      },
    }
  or {}
