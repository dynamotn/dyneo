---@diagnostic disable-next-line: unused-local
local language = require('config.languages').toml

return vim.list_contains(DyNeo.enabled_languages, 'toml')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            harper_ls = {},
          },
        },
      },
      {
        -- Work with crates of Rust
        'Saecki/crates.nvim',
        event = { 'BufRead Cargo.toml' },
        -- Any TOML buffer: they do nothing outside a Cargo.toml
        keys = {
          {
            '<localleader>p',
            function() require('crates').show_popup() end,
            desc = 'Crate Details',
            ft = 'toml',
          },
          {
            '<localleader>U',
            function() require('crates').upgrade_all_crates() end,
            desc = 'Upgrade All Crates',
            ft = 'toml',
          },
        },
        opts = {
          completion = {
            crates = {
              enabled = true,
            },
          },
          lsp = {
            enabled = true,
            actions = true,
            completion = true,
            hover = true,
          },
        },
      },
    }
  or {}
