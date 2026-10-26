-- An LSP hover is a markdown float too: not a document to spell or run
if vim.bo.buftype ~= '' then return end
vim.opt_local.wrap = true
vim.opt_local.spell = true

-- Code blocks run where they are written (`tools.runbook`), which loads on
-- the key rather than with every Markdown buffer
for lhs, map in pairs({
  ['<localleader>r'] = { 'run', 'Run Block (Runbook)' },
  ['<localleader>R'] = { 'run_all', 'Run All Blocks (Runbook)' },
  ['<localleader>F'] = { 'run_from', 'Run From Here (Runbook)' },
  ['<localleader>L'] = { 'record', 'Record Runs (Runbook)' },
  ['<localleader>x'] = { 'clear', 'Clear Outputs (Runbook)' },
  ['<localleader>s'] = { 'stop', 'Stop Running (Runbook)' },
  ['<localleader>I'] = { 'forget_inputs', 'Forget Inputs (Runbook)' },
}) do
  vim.keymap.set(
    'n',
    lhs,
    function() require('tools.runbook')[map[1]]() end,
    { buffer = true, desc = map[2] }
  )
end

-- A decision matrix is a Markdown table: the mapping lives where one is
vim.keymap.set(
  'n',
  '<localleader>m',
  '<cmd>DyMatrix<cr>',
  { buffer = true, desc = 'Decision Matrix' }
)

-- `<leader>cp` is the browser preview of the whole document: a Mermaid or
-- D2 block gets one of its own, drawn in a kitty overlay that zellij cannot
-- swallow
vim.keymap.set(
  'n',
  '<localleader>d',
  function() require('tools.diagram.block').preview(0) end,
  { buffer = true, desc = 'Preview Diagram Block' }
)
