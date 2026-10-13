local language = require('config.languages').json

return vim.list_contains(DyNeo.enabled_languages, 'json')
    and {
      {
        -- Schema
        --
        -- A library and nothing else: `before_init` below requires it when
        -- the server starts, and that is what loads it. Loading it on `ft`
        -- instead made lazy.nvim replay `FileType` for the buffer, running
        -- every handler of the filetype a second time.
        'b0o/SchemaStore.nvim',
      },
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            jsonls = {
              -- lazy-load schemastore when needed. A server's own
              -- `before_init` replaces the one `*` sets rather than running
              -- after it, so the project's local settings are read here too.
              before_init = function(_, new_config)
                require('codesettings').with_local_settings(
                  new_config.name,
                  new_config
                )
                -- Appended: a deep merge would lay SchemaStore's list over
                -- the project's one index at a time
                new_config.settings.json.schemas = vim.list_extend(
                  new_config.settings.json.schemas or {},
                  require('schemastore').json.schemas()
                )
              end,
              -- The server downloads every remote schema once and never
              -- retries, so a dropped connection costs the buffer its
              -- validation for the session unless the fetch is repeated
              on_init = function(client)
                require('util.json_schema').on_init(client)
              end,
              settings = {
                json = {
                  format = {
                    enable = true,
                  },
                  validate = { enable = true },
                },
              },
            },
          },
        },
      },
    }
  or {}
