---@type vim.lsp.Config
return {
  init_options = {
    settings = {
      lint = {
        -- Airflow's rules: a task stored under another name than its
        -- `task_id`, a DAG with no schedule, and what Airflow 3 removed or
        -- moved. They look only at code that uses Airflow, so every other
        -- file reads as before; a project's own `select` still applies.
        extendSelect = { 'AIR' },
      },
    },
  },
}
