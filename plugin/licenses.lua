-- `:DyLicenses`: the licenses of the project's dependencies against a policy.
-- The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyLicenses',
  function(args) require('tools.licenses').command(args) end,
  {
    nargs = '?',
    complete = 'file',
    desc = 'Licenses of the project dependencies, checked against a policy',
  }
)
