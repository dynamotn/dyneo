local languages = require('config.languages')

-- Every enabled table format: a comma, a tab or a pipe between its columns
local filetypes = {}
for _, name in ipairs({ 'csv', 'tsv', 'psv' }) do
  if vim.list_contains(DyNeo.enabled_languages, name) then
    vim.list_extend(filetypes, languages[name].filetypes)
  end
end

return #filetypes > 0
    and {
      {
        -- Navigation and table view
        'hat0uma/csvview.nvim',
        ft = filetypes,
        keys = {
          {
            '<localleader>v',
            '<cmd>CsvViewToggle<cr>',
            desc = 'Toggle Table View',
            ft = filetypes,
          },
        },
        -- csvview takes this map in place of its own, not merged with it
        opts = {
          parser = {
            delimiter = { ft = { csv = ',', tsv = '\t', psv = '|' } },
          },
        },
      },
    }
  or {}
