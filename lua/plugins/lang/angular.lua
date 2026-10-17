return vim.list_contains(DyNeo.enabled_languages, 'angular')
    and {
      {
        -- Extended snippets for angular. From LuaSnip's `opts`, which merge:
        -- a `config` on friendly-snippets would replace the one that loads it
        'L3MON4D3/LuaSnip',
        opts = function()
          require('luasnip').filetype_extend('htmlangular', { 'angular' })
          require('luasnip').filetype_extend('typescript', { 'angular' })
        end,
      },
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          setup = {
            angularls = function()
              Snacks.util.lsp.on({ name = 'angularls' }, function(_, client)
                --HACK: disable angular renaming capability due to duplicate rename popping up
                client.server_capabilities.renameProvider = false
              end)
            end,
          },
        },
      },
    }
  or {}
