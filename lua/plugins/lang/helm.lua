---@diagnostic disable-next-line: unused-local
local language = require('config.languages').helm

return vim.list_contains(DyNeo.enabled_languages, 'helm')
    and {
      {
        -- Filetype icons
        'nvim-mini/mini.icons',
        opts = {
          filetype = {
            helm = { glyph = '', hl = 'MiniIconsGrey' },
          },
        },
      },
    }
  or {}
