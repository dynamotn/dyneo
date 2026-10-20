-- `:DyEnvDiff [{other}]`: what differs between this settings file and
-- another environment's, key by key. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyEnvDiff',
  function(args) require('tools.envdiff').command(args) end,
  {
    nargs = '?',
    complete = 'file',
    desc = "Compare this file with another environment's, key by key",
  }
)
