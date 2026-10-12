-- `:DyHex`: the bytes of the buffer's file as a hex dump, written back on
-- `:w`. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyHex',
  function() require('tools.hex').open() end,
  { desc = "Edit the bytes of the buffer's file as a hex dump" }
)
