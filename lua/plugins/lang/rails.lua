---@diagnostic disable-next-line: unused-local
local language = require('config.languages').rails

return vim.list_contains(DyNeo.enabled_languages, 'rails')
    and {
      {
        -- Extended snippets for Rails. From LuaSnip's `opts`, which merge:
        -- a `config` on friendly-snippets would replace the one that loads it
        'L3MON4D3/LuaSnip',
        opts = function()
          require('luasnip').filetype_extend('ruby', { 'rails' })
        end,
      },
    }
  or {}
