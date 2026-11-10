-- `:[count]DyFlaky [file|stop]`: run the test under the cursor, or with
-- `file` every test of the buffer's file, {count} times (10 unless given)
-- and report how often it passes; `stop` ends a run going on. The module
-- only loads when asked.
vim.api.nvim_create_user_command(
  'DyFlaky',
  function(args) require('tools.flaky').run(args.args, args.count) end,
  {
    nargs = '?',
    count = 0,
    complete = function() return { 'file', 'stop' } end,
    desc = 'Run a test many times and tell flaky from broken',
  }
)
