-- `:DyDebt [{keyword}] [mine]`: the TODO/FIXME/HACK/XXX comments of the
-- project, oldest first, with their age and author from git blame, in the
-- quickfix list. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyDebt',
  function(args) require('tools.debt').run(args.fargs) end,
  {
    nargs = '*',
    complete = function() return { 'TODO', 'FIXME', 'HACK', 'XXX', 'mine' } end,
    desc = 'List the TODO/FIXME comments of the project, oldest first',
  }
)
