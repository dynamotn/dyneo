-- `:DyMatrix`: the totals of the decision matrix under the cursor worked
-- out, or a new one written. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyMatrix',
  function() require('tools.matrix').update() end,
  { desc = 'Work out a weighted decision matrix, or write one' }
)
