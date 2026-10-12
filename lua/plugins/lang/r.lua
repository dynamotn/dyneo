local language = require('config.languages').r
local cmp_util = require('util.cmp')

return vim.list_contains(DyNeo.enabled_languages, 'r')
    and {
      {
        -- R console in a split, and everything that talks to it
        'R-nvim/R.nvim',
        -- the plugin sets its own filetype hooks up, so it loads eagerly
        lazy = false,
        -- Every filetype it knows but `quarto`, whose chunks of any language
        -- run through quarto-nvim on the same `<localleader>` keys
        init = function()
          vim.g.R_filetypes = { 'r', 'rmd', 'rnoweb', 'rhelp', 'typst' }
        end,
        -- Every R buffer asks R for its `nvimcom` version, and fails when
        -- there is no R to ask.
        cond = function() return vim.fn.executable('R') == 1 end,
        opts = {
          R_args = { '--quiet', '--no-save' },
          pdfviewer = '',
          hook = {
            on_filetype = function()
              vim.keymap.set(
                'n',
                '<Enter>',
                '<Plug>RDSendLine',
                { buffer = true, desc = 'Send line to R' }
              )
              vim.keymap.set(
                'x',
                '<Enter>',
                '<Plug>RSendSelection',
                { buffer = true, desc = 'Send selection to R' }
              )
              require('which-key').add({
                buffer = true,
                mode = { 'n', 'x' },
                { '<localleader>a', group = 'all' },
                { '<localleader>b', group = 'between marks' },
                { '<localleader>c', group = 'chunks' },
                { '<localleader>f', group = 'functions' },
                { '<localleader>g', group = 'goto' },
                { '<localleader>i', group = 'install' },
                { '<localleader>k', group = 'knit' },
                { '<localleader>p', group = 'paragraph' },
                { '<localleader>q', group = 'quarto' },
                { '<localleader>r', group = 'r general' },
                { '<localleader>s', group = 'split or send' },
                { '<localleader>t', group = 'terminal' },
                { '<localleader>v', group = 'view' },
              })
            end,
          },
        },
        config = function(_, opts)
          vim.g.rout_follow_colorscheme = true
          require('r').setup(opts)
          require('r.pdf.generic').open = vim.ui.open
        end,
      },
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            r_language_server = {
              root_markers = { 'DESCRIPTION', 'NAMESPACE', '.Rbuildignore' },
            },
          },
        },
      },
      {
        -- Completion out of the running R session comes from R.nvim's own
        -- language server, `r_ls`, through the `lsp` source; cmp-r is
        -- archived and no longer talks to it
        'blink.cmp',
        opts = {
          sources = {
            per_filetype = {
              r = cmp_util.sources('r'),
            },
          },
        },
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'shunsambongi/neotest-testthat',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-testthat'] = {},
          },
        },
      },
    }
  or {}
