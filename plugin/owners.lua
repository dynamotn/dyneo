-- `:DyOwners [unowned]`: who CODEOWNERS says owns this file, or every file
-- nobody does. The module only loads when asked, or when the statusline
-- first shows the owners.
vim.api.nvim_create_user_command(
  'DyOwners',
  function(args) require('tools.owners').command(args) end,
  {
    nargs = '?',
    complete = function() return require('tools.owners').SUBCOMMANDS end,
    desc = 'Who owns this file, or which files nobody owns',
  }
)
