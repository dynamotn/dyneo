local language = require('config.languages').sql
local cmp_util = require('util.cmp')

vim.g.omni_sql_default_compl_type = 'syntax'
vim.g.loaded_sql_completion = true

return vim.list_contains(DyNeo.enabled_languages, 'sql')
    and {
      {
        -- Engine
        'tpope/vim-dadbod',
        cmd = 'DB',
      },
      {
        -- UI for engine
        'kristijanhusak/vim-dadbod-ui',
        cmd = { 'DBUI', 'DBUIToggle', 'DBUIAddConnection', 'DBUIFindBuffer' },
        dependencies = 'vim-dadbod',
        keys = {
          { '<leader>Db', '<cmd>DBUIToggle<CR>', desc = 'Toggle DBUI' },
        },
        init = function()
          local data_path = vim.fn.stdpath('data')

          vim.g.db_ui_auto_execute_table_helpers = 1
          vim.g.db_ui_save_location = data_path .. '/dadbod_ui'
          vim.g.db_ui_show_database_icon = true
          vim.g.db_ui_tmp_query_location = data_path .. '/dadbod_ui/tmp'
          vim.g.db_ui_use_nerd_fonts = true
          vim.g.db_ui_use_nvim_notify = true
          vim.g.db_ui_execute_on_save = false
        end,
      },
      {
        -- lualine extension for DBUI
        'lualine.nvim',
        opts = {
          special_filetypes = {
            dbui = 'Databases',
          },
        },
      },
      {
        -- SQL databases completion source
        'kristijanhusak/vim-dadbod-completion',
        ft = language.filetypes,
        init = function()
          DyNeo.completion_sources =
            vim.tbl_extend('force', DyNeo.completion_sources, {
              Dadbod = '「DB」',
            })
        end,
      },
      {
        -- SQL keywords source
        'ray-x/cmp-sql',
        ft = language.filetypes,
        init = function()
          DyNeo.completion_sources =
            vim.tbl_extend('force', DyNeo.completion_sources, {
              sql = '「SQL」',
            })
        end,
      },
      {
        -- Completion for SQL. The two sources load on their own filetypes, not
        -- as dependencies: a dependency loads with blink.cmp on the first
        -- `InsertEnter` of any buffer.
        'blink.cmp',
        opts = {
          sources = {
            compat = { 'dadbod', 'sql' },
            per_filetype = {
              sql = cmp_util.sources('sql'),
              mysql = cmp_util.sources('sql'),
              plsql = cmp_util.sources('sql'),
            },
            providers = {
              dadbod = {
                name = 'Dadbod',
                module = 'vim_dadbod_completion.blink',
              },
            },
          },
        },
      },
      {
        -- Edgy integration
        'edgy.nvim',
        optional = true,
        opts = function(_, opts)
          opts.right = opts.right or {}
          table.insert(opts.right, {
            title = 'Database',
            ft = 'dbui',
            pinned = true,
            width = 0.3,
            open = function() vim.cmd('DBUI') end,
          })

          opts.bottom = opts.bottom or {}
          table.insert(opts.bottom, {
            title = 'DB Query Result',
            ft = 'dbout',
          })
        end,
      },
    }
  or {}
