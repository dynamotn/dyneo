-- `:DyLocalHistory`: a copy of the file kept at each write, shown against the
-- buffer. The copy is taken after the write, off its way, and not while
-- quitting; the module only loads on the first write.
vim.api.nvim_create_autocmd('BufWritePost', {
  group = vim.api.nvim_create_augroup('dy_local_history', { clear = true }),
  callback = function(args)
    vim.schedule(function()
      if
        vim.v.exiting ~= vim.NIL or not vim.api.nvim_buf_is_valid(args.buf)
      then
        return
      end
      require('tools.local_history').save(args.buf)
    end)
  end,
})

vim.api.nvim_create_user_command(
  'DyLocalHistory',
  function() require('tools.local_history').open() end,
  { desc = 'Show a copy kept at an earlier write against the buffer' }
)
