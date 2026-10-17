return vim.list_contains(DyNeo.enabled_languages, 'vue')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            -- vtsls carries the TypeScript side of a component (vue_ls 3
            -- runs in hybrid mode only), and the spec below extends it
            vtsls = {},
          },
        },
      },
      {
        -- Extend LSP config of vtsls by plugin for Vue
        'neovim/nvim-lspconfig',
        opts = function(_, opts)
          require('util.plugin').extend(
            opts.servers.vtsls,
            'filetypes',
            { 'vue' }
          )
          require('util.plugin').extend(
            opts.servers.vtsls,
            'settings.vtsls.tsserver.globalPlugins',
            {
              {
                name = '@vue/typescript-plugin',
                -- A path, not a function: settings are sent to the server
                -- as JSON, and a function cannot be encoded. The package is
                -- only installed with the first Vue file, so a missing one
                -- is expected and not warned about.
                location = require('util.plugin').get_pkg_path(
                  'vue-language-server',
                  '/node_modules/@vue/language-server',
                  { warn = false }
                ),
                languages = { 'vue' },
                configNamespace = 'typescript',
                enableForWorkspaceTypeScriptVersions = true,
              },
            }
          )
        end,
      },
    }
  or {}
