---@diagnostic disable-next-line: unused-local
local language = require('config.languages').gotmpl

return vim.list_contains(DyNeo.enabled_languages, 'gotmpl')
    and {
      {
        -- Filetype icons
        'nvim-mini/mini.icons',
        opts = {
          filetype = {
            gotmpl = { glyph = '󰟓 ', hl = 'MiniIconsGrey' },
          },
        },
      },
      {
        -- Comment
        'folke/ts-comments.nvim',
        opts = {
          lang = {
            gotmpl = { '{{- /* %s */ }}' },
          },
        },
      },
    }
  or {}
