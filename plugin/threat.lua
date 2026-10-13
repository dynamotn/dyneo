-- `:DyThreat [new [{scope}]]`: a STRIDE threat model written as a decision
-- record, and the questions it leaves open. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyThreat',
  function(args) require('tools.threat').command(args) end,
  {
    nargs = '*',
    complete = function(_, line)
      if line:match('^%S+%s+%S+%s') then return {} end
      return { 'new' }
    end,
    desc = 'Write a STRIDE threat model, or list its open questions',
  }
)
