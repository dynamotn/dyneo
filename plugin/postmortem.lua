-- `:DyPostmortem [new [{title}]]`: a blameless postmortem written as a
-- decision record with its timeline gathered, and the action items it leaves
-- open. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyPostmortem',
  function(args) require('tools.postmortem').command(args) end,
  {
    nargs = '*',
    complete = function(_, line)
      if line:match('^%S+%s+%S+%s') then return {} end
      return { 'new' }
    end,
    desc = 'Write a postmortem, or list its open action items',
  }
)
