local language = require('config.languages').r

-- Every filetype R.nvim knows but `quarto`, whose chunks of any language run
-- through quarto-nvim on the same `<localleader>` keys. Typst is a document
-- with R chunks (`.Rtyp`), which R.nvim supports as it does R Markdown.
local filetypes = { 'r', 'rmd', 'rnoweb', 'rhelp', 'typst' }

return vim.list_contains(DyNeo.enabled_languages, 'r')
    and {
      {
        -- R console in a split, and everything that talks to it
        'R-nvim/R.nvim',
        -- Its hooks are ftplugins, which lazy.nvim runs again for the buffer
        -- that loaded it; its ftdetect (`.Rtyp`) lazy.nvim reads at startup
        ft = filetypes,
        init = function() vim.g.R_filetypes = filetypes end,
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
