-- `:DyReview`: review a pull request of any forge remote in one UI -- triage
-- panel, diff, drafts and threads. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyReview',
  function(args) require('tools.review').command(args) end,
  {
    nargs = '?',
    complete = function(lead, line)
      local words = vim.split(line, '%s+', { trimempty = true })
      local done = #words - (line:sub(-1) == ' ' and 0 or 1)
      if done > 1 then return {} end
      return vim.tbl_filter(
        function(word) return word:find(lead, 1, true) == 1 end,
        require('tools.review').SUBCOMMANDS
      )
    end,
    desc = 'Review a pull request: pick, branch, since, drafts, trust, close',
  }
)
