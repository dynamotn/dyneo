-- The last run of an Airflow DAG, a Prefect flow or a Dagster job, on the
-- tasks of the Python file that defines it, through `:DyCiStatus` and the
-- `<localleader>p` keys. A Python buffer is told apart by `util.ci_kind`,
-- which reads its first lines for an import; `tools.ci_inline` only loads
-- for one that imports one of them.
vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_pipelines', { clear = true }),
  pattern = 'python',
  callback = function(args)
    if not require('util.ci_kind').of(args.buf) then return end
    require('tools.ci_inline').attach(args.buf)
  end,
})
