-- `:DyDiagram`: the Mermaid or D2 block under the cursor, or the Mermaid
-- file, drawn in a kitty overlay. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyDiagram',
  function() require('tools.diagram.block').preview(0) end,
  { desc = 'Preview the Mermaid or D2 diagram under the cursor' }
)
