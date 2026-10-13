-- `:DyDeps`: the dependency rules of the project checked by the tool it is
-- set up for, what breaks in the quickfix list. The module only loads when
-- asked.
vim.api.nvim_create_user_command(
  'DyDeps',
  function() require('tools.deps').check() end,
  { desc = 'Check the dependency rules of the project' }
)
