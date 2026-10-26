-- The preview loads `tools.diagram.mermaid` on the key, not with the buffer
vim.keymap.set(
  'n',
  '<leader>cp',
  function() require('tools.diagram.mermaid').preview(0) end,
  { buffer = true, desc = 'Preview Mermaid diagram' }
)
