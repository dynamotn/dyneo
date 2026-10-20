-- `:DyNfr {term}...`: the availability, downtime and load of a system made
-- of the components given; `:DyNfr slo {objective}` the burn-rate alerts of
-- a service level objective. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyNfr',
  function(args) require('tools.nfr').command(args) end,
  {
    nargs = '*',
    complete = function(lead, line)
      if line:match('^%S+%s+%S+%s') then return {} end
      return ('slo'):find(lead, 1, true) == 1 and { 'slo' } or {}
    end,
    desc = 'Availability, downtime and load of a chain of components',
  }
)
