return vim.list_contains(DyNeo.enabled_languages, 'dockerfile')
    and {
      {
        -- Debug adapters & configurations
        'mfussenegger/nvim-dap',
        -- Loaded with nvim-dap, not on `ft`: the adapter requires nvim-dap, so
        -- loading it with the filetype brought the whole debugger along on
        -- every buffer of the language.
        dependencies = {
          'docker/nvim-dap-docker',
          opts = {},
        },
      },
    }
  or {}
