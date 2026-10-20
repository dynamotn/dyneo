local h = require('helpers')

describe('util.py_defs', function()
  local py

  before_each(function()
    h.unload('util.py_defs')
    py = require('util.py_defs')
  end)

  it('finds decorated functions, their arguments across lines', function()
    local lines = {
      'from prefect import flow, task',
      '',
      '@task',
      'def extract():',
      '    pass',
      '',
      '@task(',
      '    name="load-it",  # a comment with )',
      '    retries=2,',
      ')',
      'async def load(rows):',
      '    pass',
      '',
      '@prefect.flow(name="etl (daily)")',
      '@other',
      'def etl():',
      '    pass',
      '',
      '    @task.docker(image="x")',
      '    def inner():',
      '        pass',
      '@tasks_helper',
      'def not_one():',
      '    pass',
    }
    local defs = py.decorated(lines, { 'task', 'flow' })
    assert.same(
      {
        { 'task', '', 'extract', 3, 4 },
        {
          'task',
          'name="load-it", retries=2,',
          'load',
          7,
          11,
        },
        { 'flow', 'name="etl (daily)"', 'etl', 14, 16 },
        { 'task', 'image="x"', 'inner', 19, 20 },
      },
      vim.tbl_map(
        function(d)
          return {
            d.decorator,
            vim.trim((d.args:gsub('%s+', ' '))),
            d.func,
            d.line,
            d.def_line,
          }
        end,
        defs
      )
    )
    assert.equals('load-it', py.kwarg(defs[2].args, 'name'))
    assert.equals('etl (daily)', py.kwarg(defs[3].args, 'name'))
    assert.equals(4, defs[4].indent)
  end)

  it('reads keyword and first arguments, a word at a time', function()
    assert.equals('a', py.kwarg('task_id="a", group_id="g"', 'task_id'))
    assert.equals('g', py.kwarg('task_id="a", group_id="g"', 'group_id'))
    assert.is_nil(py.kwarg('group_id="g"', 'id'))
    assert.equals('daily', py.first_string(' "daily", schedule=None'))
    assert.equals('raw', py.first_string("r'raw'"))
    assert.is_nil(py.first_string('DAG_ID, schedule=None'))
  end)

  it('finds calls, not other names ending the same way', function()
    local calls = py.calls({
      'with DAG(',
      '    dag_id="etl",',
      ') as dag:',
      '    t = BashOperator(task_id="say", bash_command="echo")',
      'x = MyDAG("no")',
      '# DAG("commented")',
    }, { 'DAG', 'BashOperator' })
    assert.same(
      {
        { name = 'DAG', line = 1 },
        { name = 'BashOperator', line = 4 },
      },
      vim.tbl_map(
        function(c) return { name = c.name, line = c.line } end,
        calls
      )
    )
    assert.equals('etl', py.kwarg(calls[1].args, 'dag_id'))
  end)

  it('tells what a file imports', function()
    local lines = { 'import os', 'from airflow.sdk import dag, task' }
    assert.is_true(py.imports(lines, 'airflow'))
    assert.is_false(py.imports(lines, 'prefect'))
    assert.is_true(py.imports({ 'import dagster as dg' }, 'dagster'))
    assert.is_true(py.imports({ 'import prefect' }, 'prefect'))
    assert.is_false(py.imports({ 'import prefecture' }, 'prefect'))
  end)
end)
