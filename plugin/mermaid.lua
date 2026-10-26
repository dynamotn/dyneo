-- `:DyMermaid`: the Mermaid block under the cursor, or the Mermaid file,
-- drawn in a kitty overlay. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyMermaid',
  function() require('tools.diagram.mermaid').preview(0) end,
  { desc = 'Preview the Mermaid diagram under the cursor' }
)
