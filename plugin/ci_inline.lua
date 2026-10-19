-- `:DyCiStatus`, `:DyCiLint`: the last pipeline on the jobs of a
-- `.gitlab-ci.yml`, a GitHub Actions workflow, an Azure Pipelines file, a
-- `Jenkinsfile` or an Argo workflow, and the server's own check of the first
-- two. The module only loads when asked, or when such a file opens: a Groovy
-- or YAML buffer is told apart by `util.ci_kind`, which reads its name and
-- its first lines alone.
vim.api.nvim_create_user_command(
  'DyCiStatus',
  function(args) require('tools.ci_inline').command(args) end,
  {
    nargs = '?',
    complete = function() return { 'clear' } end,
    desc = 'Show the last pipeline on the jobs of this file',
  }
)

vim.api.nvim_create_user_command(
  'DyCiLint',
  function() require('tools.ci_inline').lint(0) end,
  { desc = 'Have GitLab or Jenkins check this pipeline file' }
)

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_ci_inline', { clear = true }),
  pattern = { 'yaml.gitlab', 'yaml.gh-action', 'yaml.az-pl', 'groovy', 'yaml' },
  callback = function(args)
    if not require('util.ci_kind').of(args.buf) then return end
    require('tools.ci_inline').attach(args.buf)
  end,
})
