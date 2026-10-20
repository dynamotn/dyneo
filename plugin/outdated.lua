-- `:DyOutdated [bump|clear]`: the releases the dependencies of this manifest
-- may move to, held to the quarantine window. The module only loads when
-- asked.
vim.api.nvim_create_user_command(
  'DyOutdated',
  function(args) require('tools.outdated').command(args) end,
  {
    nargs = '?',
    complete = function() return require('tools.outdated').SUBCOMMANDS end,
    desc = 'Show the releases out of quarantine the dependencies may move to',
  }
)
