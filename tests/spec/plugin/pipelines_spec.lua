local h = require('helpers')

describe('plugin/pipelines', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.ci_inline', {
      attach = function(bufnr) table.insert(calls, bufnr) end,
    })
    dofile(h.root .. '/plugin/pipelines.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_augroup_by_name('dy_pipelines')
    vim.cmd('silent! %bwipeout!')
  end)

  it('attaches only to a Python file importing a data pipeline', function()
    local dag = h.buffer({
      lines = { 'from airflow.sdk import DAG' },
      filetype = 'python',
    })
    h.buffer({ lines = { 'import os' }, filetype = 'python' })
    h.buffer({ lines = { 'import dagster' }, filetype = 'lua' })
    assert.same({ dag }, calls)
  end)
end)
