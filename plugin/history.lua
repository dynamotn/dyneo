-- `:[range]DyHistory`: the commits that changed the definition under the
-- cursor, or the lines given. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyHistory',
  function(args) require('tools.history').command(args) end,
  {
    range = true,
    desc = 'The history of the function under the cursor, or of the lines',
  }
)
