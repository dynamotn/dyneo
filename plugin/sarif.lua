-- `:DySarif`: the findings of a code scanner's SARIF report, in the quickfix
-- list. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DySarif',
  function(args) require('tools.sarif').command(args) end,
  {
    nargs = '?',
    complete = 'file',
    desc = 'List the findings of a SARIF report in the quickfix list',
  }
)
