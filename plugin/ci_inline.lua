-- `:DyCiStatus`, `:DyCiLint`: the last pipeline of the branch on the jobs of a
-- `.gitlab-ci.yml`, a GitHub Actions workflow or an Azure Pipelines file, and
-- GitLab's own check of the first. The module only loads when asked, or when
-- such a file opens.
vim.api.nvim_create_user_command(
  'DyCiStatus',
  function(args) require('tools.ci_inline').command(args) end,
  {
    nargs = '?',
    complete = function() return { 'clear' } end,
    desc = 'Show the last pipeline of the branch on the jobs of this file',
  }
)

vim.api.nvim_create_user_command(
  'DyCiLint',
  function() require('tools.ci_inline').lint(0) end,
  { desc = 'Have GitLab check this .gitlab-ci.yml' }
)

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_ci_inline', { clear = true }),
  pattern = { 'yaml.gitlab', 'yaml.gh-action', 'yaml.az-pl' },
  callback = function(args) require('tools.ci_inline').attach(args.buf) end,
})
