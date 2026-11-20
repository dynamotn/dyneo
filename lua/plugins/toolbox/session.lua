return {
  {
    -- Save the session in the background: buffers, windows and more. The
    -- dashboard restores it.
    'folke/persistence.nvim',
    event = 'BufReadPre',
    opts = {},
    init = function()
      -- A session keeps a tab of tool buffers (`:DyProject`, `:DyHistory`,
      -- a diff, a search and replace) as an empty tab and an empty buffer of
      -- the same name: on the way out, before it is saved, they go
      vim.api.nvim_create_autocmd('User', {
        group = vim.api.nvim_create_augroup('dyneo_session', { clear = true }),
        pattern = 'PersistenceSavePre',
        callback = function()
          local function scratch(bufnr) return vim.bo[bufnr].buftype == 'nofile' end
          for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
            local wins = vim.api.nvim_tabpage_list_wins(tab)
            local tools = vim.iter(wins):all(
              function(win) return scratch(vim.api.nvim_win_get_buf(win)) end
            )
            if tools and #vim.api.nvim_list_tabpages() > 1 then
              pcall(vim.cmd.tabclose, vim.api.nvim_tabpage_get_number(tab))
            end
          end
          for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
            if vim.bo[bufnr].buflisted and scratch(bufnr) then
              pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
          end
        end,
      })
    end,
    -- stylua: ignore
    keys = {
      { '<leader>qs', function() require('persistence').load() end, desc = 'Restore Session' },
      { '<leader>qS', function() require('persistence').select() end, desc = 'Select Session' },
      { '<leader>ql', function() require('persistence').load({ last = true }) end, desc = 'Restore Last Session' },
      { '<leader>qd', function() require('persistence').stop() end, desc = "Don't Save Current Session" },
    },
  },
  -- Library used by other plugins
  { 'nvim-lua/plenary.nvim', lazy = true },
}
