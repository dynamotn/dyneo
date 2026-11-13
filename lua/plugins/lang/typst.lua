local language = require('config.languages').typst
local cmp_util = require('util.cmp')

return vim.list_contains(DyNeo.enabled_languages, 'typst')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            tinymist = {
              keys = {
                {
                  '<leader>cP',
                  function()
                    local buf_name = vim.api.nvim_buf_get_name(0)
                    require('util.lsp').execute({
                      command = 'tinymist.pinMain',
                      arguments = { buf_name },
                    })
                  end,
                  ft = language.filetypes,
                  desc = 'Pin main file',
                },
              },
              settings = {
                formatterMode = 'typstyle',
              },
            },
          },
        },
      },
      {
        -- Typst preview. Loaded when asked, not by a Typst buffer: its setup
        -- downloads the binaries it lacks (`websocat`) from GitHub.
        'chomosuke/typst-preview.nvim',
        cmd = { 'TypstPreview', 'TypstPreviewToggle', 'TypstPreviewUpdate' },
        keys = {
          {
            '<leader>cp',
            ft = language.filetypes,
            '<cmd>TypstPreviewToggle<cr>',
            desc = 'Toggle Typst Preview',
          },
        },
        opts = {
          dependencies_bin = {
            tinymist = 'tinymist',
          },
        },
      },
      {
        -- Comment
        'folke/ts-comments.nvim',
        opts = {
          lang = {
            typst = { '// %s', '/* %s */' },
          },
        },
      },
      {
        -- Completion
        'blink.cmp',
        opts = {
          sources = {
            per_filetype = {
              typst = cmp_util.sources('typst'),
            },
          },
        },
      },
    }
  or {}
