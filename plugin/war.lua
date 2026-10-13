-- `:DyWar [new]`: a Well-Architected review written as a decision record,
-- and the questions it leaves open. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyWar',
  function(args) require('tools.war').command(args) end,
  {
    nargs = '?',
    complete = function() return { 'new' } end,
    desc = 'Write a Well-Architected review, or list its open questions',
  }
)
