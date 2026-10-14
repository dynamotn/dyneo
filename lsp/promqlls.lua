return {
  cmd = { 'promql-langserver', '--config-file', 'promql-lsp.yaml' },
  filetypes = {
    'promql', -- *.promql
    'yaml', -- *.yaml (queries inside)
  },
  root_markers = { 'promql-lsp.yaml' },
  -- The config file is read from the root, and the server exits without
  -- one: started on any other YAML buffer, it would die at once
  workspace_required = true,
}
