-- `:DyBreaking [{rev}]`: what this Protobuf or GraphQL contract breaks of
-- itself at {rev}. The module only loads when asked, or with such a file.
vim.api.nvim_create_user_command(
  'DyBreaking',
  function(args) require('tools.breaking').diff(0, args.fargs[1]) end,
  {
    nargs = '?',
    desc = 'The breaking changes of this Protobuf or GraphQL schema since a revision',
  }
)

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_breaking', { clear = true }),
  pattern = { 'proto', 'graphql' },
  callback = function(args) require('tools.breaking').attach(args.buf) end,
})
