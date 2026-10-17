---@diagnostic disable-next-line: unused-local
local language = require('config.languages').latex

vim.g.tex_flavor = 'latex'

return vim.list_contains(DyNeo.enabled_languages, 'latex')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            -- Grammar for LaTeX only: its shipped list reaches markdown and
            -- git commits, which `harper_ls` already checks
            ltex_plus = { filetypes = { 'tex', 'plaintex', 'bib' } },
          },
        },
      },
    }
  or {}
