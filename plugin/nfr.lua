-- `:DyNfr {term}...`: the availability, downtime and load of a system made
-- of the components given. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyNfr',
  function(args) require('tools.nfr').command(args) end,
  {
    nargs = '*',
    desc = 'Availability, downtime and load of a chain of components',
  }
)
