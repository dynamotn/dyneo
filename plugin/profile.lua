-- `:DyProfile [program args...]`: run the buffer's program under a sampling
-- profiler and mark its hot lines; `:DyProfile load [file]` reads a profile
-- recorded elsewhere. The module only loads when asked.
vim.api.nvim_create_user_command('DyProfile', function(opts)
  local profile = require('tools.profile')
  if opts.fargs[1] == 'load' then return profile.load_command(opts.fargs[2]) end
  profile.run(opts.fargs)
end, {
  nargs = '*',
  complete = function(arg, line)
    if line:match('^%S+%s+load%s') then
      return vim.fn.getcompletion(arg, 'file')
    end
    return vim.tbl_filter(
      function(sub) return vim.startswith(sub, arg) end,
      { 'load' }
    )
  end,
  desc = 'Profile the program of the buffer, or load a profile',
})
