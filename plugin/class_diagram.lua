-- `:DyClassDiagram`: the classes of the buffer and what they extend, as a
-- Mermaid diagram from its language server. The module only loads when
-- asked.
vim.api.nvim_create_user_command(
  'DyClassDiagram',
  function() require('tools.class_diagram').open() end,
  { desc = 'A Mermaid class diagram of the buffer, from its language server' }
)
