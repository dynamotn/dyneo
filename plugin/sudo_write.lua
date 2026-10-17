-- `:DySudoWrite`: save the buffer with root permission. `:w !sudo tee %`
-- cannot work in Neovim: `:!` runs without a terminal, so sudo has nowhere to
-- ask for the password. The buffer is written to a private temporary file
-- instead, and copied over the file by `sudo cp` in a terminal of its own --
-- `cp` onto an existing file keeps its owner and mode. `config.keymaps` adds
-- the `:ww` shorthand.
vim.api.nvim_create_user_command('DySudoWrite', function()
  local bufnr = vim.api.nvim_get_current_buf()
  local target = vim.api.nvim_buf_get_name(bufnr)
  if target == '' then
    return vim.notify(
      'DySudoWrite: the buffer has no file',
      vim.log.levels.ERROR
    )
  end
  local tmp = vim.fn.tempname()
  vim.cmd('silent noautocmd keepalt write! ' .. vim.fn.fnameescape(tmp))
  vim.cmd('botright 6split')
  local term = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_win_set_buf(0, term)
  vim.fn.jobstart({ 'sudo', 'cp', tmp, target }, {
    term = true,
    on_exit = function(_, code)
      vim.schedule(function()
        vim.fn.delete(tmp)
        if code ~= 0 then
          return vim.notify('DySudoWrite failed', vim.log.levels.ERROR)
        end
        pcall(vim.api.nvim_buf_delete, term, { force = true })
        if vim.api.nvim_buf_is_valid(bufnr) then
          vim.bo[bufnr].modified = false
          vim.cmd.checktime(bufnr)
        end
      end)
    end,
  })
  vim.cmd.startinsert()
end, { desc = 'Write the buffer with root permission' })
