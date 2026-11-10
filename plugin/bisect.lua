-- `:DyBisect [{good} [{bad}]] [-- {cmd}]`: find the commit that broke a
-- check with `git bisect run`, in a throwaway worktree, and show it;
-- `:DyBisect stop` ends a run. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyBisect',
  function(args) require('tools.bisect').command(args.args) end,
  {
    nargs = '*',
    complete = function() return { 'stop' } end,
    desc = 'Find the commit that broke a check (git bisect run)',
  }
)
