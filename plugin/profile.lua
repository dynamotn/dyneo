-- `:DyProfile [program args...]`: run the buffer's program under a sampling
-- profiler and mark its hot lines; `:DyProfile load [file]` reads a profile
-- recorded elsewhere, `:DyProfile flame` draws the loaded one as a flame
-- graph. The module only loads when asked.
vim.api.nvim_create_user_command('DyProfile', function(opts)
  local profile = require('tools.profile')
  if opts.fargs[1] == 'load' then return profile.load_command(opts.fargs[2]) end
  if opts.fargs[1] == 'flame' and #opts.fargs == 1 then
    return profile.flame()
  end
  profile.run(opts.fargs)
end, {
  nargs = '*',
  complete = function(arg, line)
    if line:match('^%S+%s+load%s') then
      return vim.fn.getcompletion(arg, 'file')
    end
    return vim.tbl_filter(
      function(sub) return vim.startswith(sub, arg) end,
      { 'load', 'flame' }
    )
  end,
  desc = 'Profile the program of the buffer, load a profile or draw it',
})
