-- `:DyPatchCoverage [{ref}|toggle|clear]`: the coverage of the lines changed
-- since the merge base with the default branch (or with {ref}), from the
-- newest coverage report of the project. The module only loads when asked.
vim.api.nvim_create_user_command('DyPatchCoverage', function(args)
  local coverage = require('tools.patch_coverage')
  if args.args == 'clear' then return coverage.clear() end
  if args.args == 'toggle' then return coverage.toggle() end
  coverage.run(args.args ~= '' and args.args or nil)
end, {
  nargs = '?',
  complete = function() return { 'toggle', 'clear' } end,
  desc = 'Show the coverage of the lines changed since the default branch',
})
