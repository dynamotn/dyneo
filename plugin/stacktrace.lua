-- `:[range]DyStackTrace`: the frames of a stack trace -- the range, a log
-- buffer, or the clipboard -- in the quickfix list. The module only loads
-- when asked.
vim.api.nvim_create_user_command('DyStackTrace', function(args)
  local stacktrace = require('tools.stacktrace')
  stacktrace.run(stacktrace.input(args))
end, {
  range = true,
  desc = 'List the frames of a stack trace in the quickfix list',
})
