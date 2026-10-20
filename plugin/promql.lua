-- `:[range]DyPromQL`: the PromQL expression under the cursor, or the lines
-- given, asked of the clone's Prometheus; `:DyPromQL test` checks or tests
-- the rules of the buffer with promtool. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyPromQL',
  function(args) require('tools.promql').command(args) end,
  {
    nargs = '?',
    range = true,
    complete = function() return require('tools.promql').SUBCOMMANDS end,
    desc = 'Run the PromQL expression under the cursor, or test the rules',
  }
)
