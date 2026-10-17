---@diagnostic disable-next-line: unused-local
local language = require('config.languages').terragrunt

return vim.list_contains(DyNeo.enabled_languages, 'terragrunt')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          setup = {
            terragruntls = function(_, _)
              Snacks.util.lsp.on({ name = 'terragruntls' }, function(_, client)
                --HACK: disable terragruntls diagnostics due to false positives
                client.handlers['textDocument/publishDiagnostics'] = function() end
              end)
            end,
          },
        },
      },
    }
  or {}
