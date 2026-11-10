-- `:DySnapshots [accept-all|reject-all]`: review the pending snapshot-test
-- changes of the project (insta, jest, vitest, syrupy) and accept or reject
-- each, or all at once. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DySnapshots',
  function(args) require('tools.snapshots').open(args.args) end,
  {
    nargs = '?',
    complete = function() return { 'accept-all', 'reject-all' } end,
    desc = 'Review pending snapshot-test changes',
  }
)
