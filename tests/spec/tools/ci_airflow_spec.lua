local h = require('helpers')

local DAG = {
  'from airflow.sdk import DAG, dag, task, task_group',
  'from airflow.providers.standard.operators.bash import BashOperator',
  '',
  'with DAG(',
  '    dag_id="etl",',
  '    schedule=None,',
  ') as d:',
  '    say = BashOperator(task_id="say", bash_command="echo hi")',
  '',
  '    @task',
  '    def extract():',
  '        return [1, 2]',
  '',
  '    @task.bash(task_id="load_rows")',
  '    def load():',
  '        return "true"',
  '',
  '    @task_group(group_id="checks")',
  '    def checks():',
  '        BashOperator(task_id="count", bash_command="true")',
  '',
  '@dag(schedule=None)',
  'def nightly():',
  '    pass',
}

describe('tools.ci_airflow', function()
  local airflow, dir, cleanup, path

  local function cli(name, lines)
    h.write(
      dir .. '/bin/' .. name,
      vim.list_extend(
        { '#!/bin/sh', 'echo "$@" >> "' .. dir .. '/calls"' },
        lines
      )
    )
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function await(fn)
    local done, got = false, nil
    fn(function(...)
      done, got = true, { ... }
    end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    return got
  end

  before_each(function()
    h.globals()
    h.unload('tools.ci_airflow', 'util.ci_http', 'util.py_defs')
    airflow = require('tools.ci_airflow')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
  end)
  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  it('finds the DAGs and the tasks of a file', function()
    assert.same(
      { { id = 'etl', line = 4 }, { id = 'nightly', line = 22 } },
      airflow.dags(DAG)
    )
    assert.same({
      say = 8,
      extract = 10,
      load_rows = 14,
      checks = 18,
      count = 20,
    }, airflow.job_lines(DAG))
  end)

  it('asks Airflow 3 only with a token, and only of its server', function()
    DyNeo.pipelines.airflow_url = 'https://airflow.example.com'
    local got = await(function(cb) airflow.target(dir, 'etl', cb) end)
    assert.is_nil(got[1])
    assert.is_truthy(got[2]:find('airflow_token_command', 1, true))

    cli('token', { 'echo jwt' })
    DyNeo.pipelines.airflow_token_command = { dir .. '/bin/token' }
    got = await(function(cb) airflow.target(dir, 'etl', cb) end)
    assert.same({
      url = 'https://airflow.example.com',
      api = 'v2',
      dag = 'etl',
      token = 'jwt',
    }, got[1])

    vim
      .system(
        { 'git', 'config', 'dyneo.airflowUrl', 'https://other.example' },
        { cwd = dir }
      )
      :wait()
    got = await(function(cb) airflow.target(dir, 'etl', cb) end)
    assert.same(
      { nil, 'The token is for airflow.example.com, not other.example' },
      got
    )

    DyNeo.pipelines.airflow_api = 'v1'
    got = await(function(cb) airflow.target(dir, 'etl', cb) end)
    assert.same(
      { url = 'https://other.example', api = 'v1', dag = 'etl' },
      got[1]
    )
  end)

  local v2 = {
    url = 'https://af.example',
    api = 'v2',
    dag = 'etl',
    token = 'jwt',
  }

  it('reads the last run and every page of its tasks', function()
    airflow.PER_PAGE = 2
    cli('curl', {
      'cat > /dev/null',
      'case "$*" in',
      [[  *"dagRuns?order_by=-run_after&limit=1"*) echo '{"dag_runs":[{"dag_run_id":"manual__1","state":"failed"}]}';;]],
      [[  *"offset=0"*) echo '{"task_instances":[{"task_id":"say","state":"success","try_number":1,"map_index":-1},{"task_id":"extract","state":"failed","try_number":2,"map_index":-1}],"total_entries":3}';;]],
      [[  *"offset=2"*) echo '{"task_instances":[{"task_id":"checks.count","state":"upstream_failed","try_number":0,"map_index":1}],"total_entries":3}';;]],
      'esac',
    })
    local pipeline = await(function(cb) airflow.fetch(v2, cb) end)[1]
    assert.same({
      id = 'manual__1',
      status = 'failed',
      url = 'https://af.example/dags/etl/runs/manual__1',
      jobs = {
        {
          id = 'say',
          name = 'say',
          status = 'success',
          try = 1,
          map_index = -1,
        },
        {
          id = 'extract',
          name = 'extract',
          status = 'failed',
          try = 2,
          map_index = -1,
        },
        {
          id = 'checks.count',
          name = 'checks.count[1]',
          status = 'upstream_failed',
          try = 0,
          map_index = 1,
        },
      },
    }, pipeline)
    local ci = require('tools.ci_inline')
    assert.same({
      { line = 8, bucket = 'pass', count = 1 },
      { line = 10, bucket = 'fail', count = 1 },
      { line = 20, bucket = 'skipped', count = 1 },
    }, ci.marks(pipeline.jobs, airflow.job_lines(DAG), 'airflow'))
    -- The token went on standard input, never in the arguments
    for _, call in ipairs(vim.fn.readfile(dir .. '/calls')) do
      assert.is_nil(call:find('jwt', 1, true))
    end
  end)

  it('says when the DAG is unknown or never ran', function()
    cli('curl', {
      'cat > /dev/null',
      [[echo 'curl: (22) The requested URL returned error: 404' >&2]],
      'exit 22',
    })
    assert.same(
      { nil, 'No DAG etl on https://af.example' },
      await(function(cb) airflow.fetch(v2, cb) end)
    )
    cli('curl', { 'cat > /dev/null', [[echo '{"dag_runs":[]}']] })
    assert.same(
      { nil, 'No run of etl' },
      await(function(cb) airflow.fetch(v2, cb) end)
    )
  end)

  it('reads the log of a try, as text or as JSON lines', function()
    local job = { id = 'extract', name = 'extract', try = 2, map_index = -1 }
    cli('curl', {
      'cat > /dev/null',
      [[printf '{"content":[{"timestamp":"t","event":"start"},"plain"]}\n{"content":{"event":"Task failed"}}\n']],
    })
    local got = await(
      function(cb) airflow.log(v2, { id = 'manual__1' }, job, 4096, cb) end
    )
    assert.same({ 'start\nplain\nTask failed', false, nil, false }, got)
    local call = vim.fn.readfile(dir .. '/calls')[1]
    assert.is_truthy(
      call:find(
        '/api/v2/dags/etl/dagRuns/manual__1/taskInstances/extract/logs/2?full_content=true&map_index=-1',
        1,
        true
      )
    )
    assert.is_truthy(call:find('Accept: application/x-ndjson', 1, true))

    local v1 = { url = 'https://af.example', api = 'v1', dag = 'etl' }
    cli('curl', { 'printf "line one\\nline two\\n"' })
    got = await(
      function(cb) airflow.log(v1, { id = 'manual__1' }, job, 4096, cb) end
    )
    assert.same({ 'line one\nline two\n', false, nil, false }, got)
    -- A first line cut short is no JSON, and is dropped
    assert.equals('b', airflow.ndjson_text('nt":"a"}\n{"content":"b"}\n', true))
  end)
end)
