-- `:DyCert [file]`: every certificate of a file or the buffer, and whether
-- its chain holds together. A binary DER or PKCS#7 file opens as that report
-- rather than its bytes. The module only loads when asked, or when such a
-- file is read.
vim.api.nvim_create_user_command(
  'DyCert',
  function(args) require('tools.cert').command(args) end,
  {
    nargs = '?',
    complete = 'file',
    desc = 'Show and check the certificates of a file or the buffer',
  }
)

vim.api.nvim_create_autocmd('BufReadPost', {
  group = vim.api.nvim_create_augroup('dy_cert', { clear = true }),
  pattern = { '*.der', '*.cer', '*.crt', '*.cert', '*.p7b', '*.p7c' },
  callback = function(event) require('tools.cert').read(event.buf) end,
  desc = 'Show a binary certificate file as what it says',
})
