-- The plan of the statement under the cursor, or of the selection, on the
-- buffer's connection (`tools.explain`, loaded on the key)
vim.keymap.set(
  { 'n', 'x' },
  '<localleader>e',
  ':DyExplain<cr>',
  { buffer = true, silent = true, desc = 'Explain Query Plan' }
)
vim.keymap.set(
  { 'n', 'x' },
  '<localleader>E',
  ':DyExplain analyze<cr>',
  { buffer = true, silent = true, desc = 'Explain Analyze (runs it)' }
)
