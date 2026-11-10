-- `:[range]DyExplain [analyze]`: the query plan of the SQL statement under
-- the cursor, or of the range, as a tree on the buffer's dadbod connection.
-- The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyExplain',
  function(args)
    require('tools.explain').run({
      analyze = args.args == 'analyze',
      range = args.range > 0 and { args.line1, args.line2 } or nil,
    })
  end,
  {
    nargs = '?',
    range = true,
    complete = function() return { 'analyze' } end,
    desc = 'Show the query plan of the SQL statement under the cursor',
  }
)
