-- `:[count]DyCallGraph [incoming|outgoing|both] [{depth}]`: the callers and
-- callees of the function under the cursor as a Mermaid diagram, from its
-- language server. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyCallGraph',
  function(args) require('tools.callgraph').command(args) end,
  {
    nargs = '*',
    count = 0,
    complete = function() return { 'both', 'incoming', 'outgoing' } end,
    desc = 'A Mermaid call graph of the function under the cursor',
  }
)
