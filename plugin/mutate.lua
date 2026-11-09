-- `:DyMutate [%|file|load|clear]`: run the mutation tool of the project in a
-- terminal and mark the mutants its tests let survive; `%` or `file` limits
-- it to the buffer's file, `load` reads the last report again, `clear`
-- removes the marks. The module only loads when asked.
vim.api.nvim_create_user_command('DyMutate', function(args)
  local mutate = require('tools.mutate')
  if args.args == '' then
    mutate.run()
  elseif args.args == '%' or args.args == 'file' then
    mutate.run(true)
  elseif args.args == 'load' then
    mutate.load()
  elseif args.args == 'clear' then
    mutate.clear()
  else
    vim.notify(
      ('Unknown argument: %s'):format(args.args),
      vim.log.levels.ERROR,
      { title = 'DyNeo Mutate' }
    )
  end
end, {
  nargs = '?',
  complete = function() return { 'file', 'load', 'clear' } end,
  desc = 'Mutation testing: mark the code the tests run but do not check',
})
