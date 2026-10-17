local language = require('config.languages').fish
local cmp_util = require('util.cmp')

return vim.list_contains(DyNeo.enabled_languages, 'fish')
    and {
      {
        -- Completion source. Its own spec rather than a dependency of
        -- blink.cmp, which would load it on the first `InsertEnter` of any
        -- buffer.
        'mtoohey31/cmp-fish',
        ft = language.filetypes,
        init = function()
          DyNeo.completion_sources =
            vim.tbl_extend('force', DyNeo.completion_sources, {
              fish = '「FISH」',
            })
        end,
      },
      {
        -- Completion
        'blink.cmp',
        opts = {
          sources = {
            compat = { 'fish' },
            per_filetype = {
              fish = cmp_util.sources('fish'),
            },
          },
        },
      },
    }
  or {}
