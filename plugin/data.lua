-- `:DyData`: a Parquet, CSV or JSON file summed up, and SQL run over data
-- files, through DuckDB. A `.parquet` file opens as its summary rather than
-- its bytes. The module only loads when asked.
vim.api.nvim_create_user_command(
  'DyData',
  function(args) require('tools.data').command(args) end,
  {
    nargs = '*',
    range = true,
    complete = function(lead, line)
      return require('tools.data').complete(lead, line)
    end,
    desc = 'Sum up a data file, or run SQL over data files, through DuckDB',
  }
)

vim.api.nvim_create_autocmd('BufReadCmd', {
  group = vim.api.nvim_create_augroup('dy_data', { clear = true }),
  pattern = { '*.parquet' },
  callback = function(event) require('tools.data').read(event.buf) end,
  desc = 'Show a Parquet file as its summary',
})
