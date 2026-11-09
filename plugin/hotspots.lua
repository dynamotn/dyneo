-- `:DyHotspots`: the files of the project most worth refactoring, by git
-- churn times complexity, in the quickfix list. `:DyHotspots buffer` toggles
-- hints on the complex functions of the buffer. The module only loads when
-- asked.
vim.api.nvim_create_user_command('DyHotspots', function(args)
  if args.args == 'buffer' then
    require('tools.hotspots').buffer()
  elseif args.args == '' then
    require('tools.hotspots').run()
  else
    vim.notify(
      ('Unknown argument: %s'):format(args.args),
      vim.log.levels.ERROR,
      { title = 'DyNeo Hotspots' }
    )
  end
end, {
  nargs = '?',
  complete = function() return { 'buffer' } end,
  desc = 'List the files of the project most worth refactoring',
})
