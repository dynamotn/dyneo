-- `# %%` cells (`util.cells`): `]j` and `[j` move between them, `aj` and `ij`
-- select one -- `j` for Jupyter, since vim-matchup owns `%` -- and iron.nvim
-- sends them to the REPL
local cells = require('util.cells')
vim.keymap.set(
  { 'n', 'x', 'o' },
  ']j',
  function() cells.jump() end,
  { buffer = true, desc = 'Next Cell' }
)
vim.keymap.set(
  { 'n', 'x', 'o' },
  '[j',
  function() cells.jump(true) end,
  { buffer = true, desc = 'Previous Cell' }
)
vim.b.miniai_config = { custom_textobjects = { j = cells.textobject } }
