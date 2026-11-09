-- `:DyBench [cmd {command}|compare [{ref}]|list]`: run the benchmarks of the
-- project in a terminal, keep the result and compare it with the previous
-- one; `cmd` times any command with hyperfine, `compare` the last two results
-- or the last against the one recorded at a git ref, `list` picks a result.
-- The module only loads when asked.
vim.api.nvim_create_user_command('DyBench', function(args)
  local bench = require('tools.bench')
  local sub, rest = args.args:match('^(%S*)%s*(.-)%s*$')
  if sub == '' then
    bench.run()
  elseif sub == 'cmd' then
    bench.run_cmd(rest)
  elseif sub == 'compare' then
    bench.compare_cmd(rest ~= '' and rest or nil)
  elseif sub == 'list' and rest == '' then
    bench.list()
  else
    vim.notify(
      ('Unknown argument: %s'):format(args.args),
      vim.log.levels.ERROR,
      { title = 'DyNeo Bench' }
    )
  end
end, {
  nargs = '*',
  complete = function(arg, line)
    if line:match('^%S+%s+%S+%s') then return {} end
    return vim.tbl_filter(
      function(sub) return vim.startswith(sub, arg) end,
      { 'cmd', 'compare', 'list' }
    )
  end,
  desc = 'Run the benchmarks of the project and compare with the last run',
})
