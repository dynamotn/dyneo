-- `:DyHex`: the bytes of the buffer's file as a hex dump, written back on
-- `:w`. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyHex',
  function() require('tools.hex').open() end,
  { desc = "Edit the bytes of the buffer's file as a hex dump" }
)

-- A dump is read from its file whenever Vim loads the buffer: on `:DyHex`,
-- `:e!` and a session restored. Without this the buffer comes up empty, and
-- a `:w` would empty the file.
vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('dy_hex_read', { clear = true }),
  pattern = 'dyhex://*',
  callback = function(args) require('tools.hex').read(args.buf) end,
})
