-- `:DyC4 [{view}]`: a view of the LikeC4 workspace of the buffer, drawn
-- through D2. The module only loads when asked, or with a LikeC4 file.
vim.api.nvim_create_user_command(
  'DyC4',
  function(args) require('tools.c4').show(args.fargs[1]) end,
  { nargs = '?', desc = 'Draw a view of the LikeC4 workspace' }
)

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_c4', { clear = true }),
  pattern = 'likec4',
  callback = function(args) require('tools.c4').attach(args.buf) end,
})
