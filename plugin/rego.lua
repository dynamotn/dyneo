-- `:DyRego [{input}]`: this Rego policy tried against an input as it is
-- typed; `:DyRego test` its tests and coverage. The module only loads when
-- asked.
vim.api.nvim_create_user_command(
  'DyRego',
  function(args) require('tools.rego').command(args) end,
  {
    nargs = '?',
    complete = function(lead)
      return vim.list_extend(
        vim.tbl_filter(
          function(word) return word:find(lead, 1, true) == 1 end,
          require('tools.rego').SUBCOMMANDS
        ),
        vim.fn.getcompletion(lead, 'file')
      )
    end,
    desc = 'Try this Rego policy against an input, or run its tests',
  }
)
