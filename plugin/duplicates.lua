-- `:DyDuplicates [{dir}]`: the duplicated code of the project, or of {dir},
-- in the quickfix list. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyDuplicates',
  function(args)
    require('tools.duplicates').run(args.args ~= '' and args.args or nil)
  end,
  {
    nargs = '?',
    complete = 'dir',
    desc = 'List the duplicated code of the project in the quickfix list',
  }
)
