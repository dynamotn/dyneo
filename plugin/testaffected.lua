-- `:DyTestAffected [{ref}]`: run only the tests the change since the merge
-- base with the default branch (or with {ref}) affects, through neotest. The
-- module only loads when asked.
vim.api.nvim_create_user_command(
  'DyTestAffected',
  function(args)
    require('tools.testaffected').run(args.args ~= '' and args.args or nil)
  end,
  {
    nargs = '?',
    desc = 'Run the tests affected by the change since the default branch',
  }
)
