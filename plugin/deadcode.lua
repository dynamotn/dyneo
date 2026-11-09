-- `:DyDeadCode [{tool}]`: what nothing uses in the project, by every tool
-- that applies to it or by {tool} alone, in the quickfix list. The module
-- only loads when asked.
vim.api.nvim_create_user_command(
  'DyDeadCode',
  function(args)
    require('tools.deadcode').run(args.args ~= '' and args.args or nil)
  end,
  {
    nargs = '?',
    complete = function() return require('tools.deadcode').complete() end,
    desc = 'List the code nothing uses in the project',
  }
)
