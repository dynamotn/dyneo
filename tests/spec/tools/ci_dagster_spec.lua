local h = require('helpers')

local DEFS = {
  'import dagster as dg',
  '',
  '@dg.asset',
  'def raw_orders():',
  '    return []',
  '',
  '@dg.asset(key_prefix="sales", deps=[raw_orders])',
  'def orders():',
  '    return []',
  '',
  '@dg.op(name="notify_team")',
  'def notify():',
  '    pass',
  '',
  '@dg.job',
  'def nightly():',
  '    notify()',
  '',
  'daily = dg.define_asset_job("daily_refresh", selection="*")',
}

describe('tools.ci_dagster', function()
  local dagster, dir, cleanup, path

  local function cli(name, lines)
    h.write(
      dir .. '/bin/' .. name,
      vim.list_extend({
        '#!/bin/sh',
        'printf "%s\\n" "$*" >> "' .. dir .. '/calls"',
        'cat >> "' .. dir .. '/stdin"',
      }, lines)
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
    h.unload('tools.ci_dagster', 'util.ci_http', 'util.py_defs')
    dagster = require('tools.ci_dagster')
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

  it('finds jobs, assets and ops, by the step each runs as', function()
    assert.same({
      { id = 'nightly', line = 15 },
      { id = 'daily_refresh', line = 19 },
    }, dagster.jobs(DEFS))
    assert.same({
      raw_orders = 3,
      sales__orders = 7,
      notify_team = 11,
      nightly = 15,
      daily_refresh = 19,
    }, dagster.job_lines(DEFS))
    assert.is_true(dagster.has_assets(DEFS))
  end)

  it('gives a Dagster+ token only to its own deployment', function()
    DyNeo.pipelines.dagster_url = 'https://acme.dagster.cloud/prod'
    h.write(dir .. '/bin/token', { '#!/bin/sh', 'echo user-token' })
    vim.fn.setfperm(dir .. '/bin/token', 'rwxr-xr-x')
    DyNeo.pipelines.dagster_token_command = { dir .. '/bin/token' }
    local got = await(function(cb) dagster.target(dir, 'nightly', cb) end)
    assert.same({
      url = 'https://acme.dagster.cloud/prod',
      job = 'nightly',
      token = 'user-token',
    }, got[1])
    vim
      .system(
        { 'git', 'config', 'dyneo.dagsterUrl', 'https://evil.example' },
        { cwd = dir }
      )
      :wait()
    got = await(function(cb) dagster.target(dir, 'nightly', cb) end)
    assert.same(
      { nil, 'The token is for acme.dagster.cloud, not evil.example' },
      got
    )
  end)

  local target = {
    url = 'https://acme.dagster.cloud/prod',
    job = 'nightly',
    token = 'user-token',
  }

  it('reads the last run of a job and its steps', function()
    cli('curl', {
      [[echo '{"data":{"runsOrError":{"__typename":"Runs","results":[{"runId":"abc","status":"FAILURE","stepStats":[{"stepKey":"raw_orders","status":"SUCCESS"},{"stepKey":"notify_team","status":"FAILURE"}]}]}}}']],
    })
    local pipeline = await(function(cb) dagster.fetch(target, cb) end)[1]
    assert.same({
      id = 'abc',
      status = 'FAILURE',
      url = 'https://acme.dagster.cloud/prod/runs/abc',
      jobs = {
        { id = 'raw_orders', name = 'raw_orders', status = 'SUCCESS' },
        { id = 'notify_team', name = 'notify_team', status = 'FAILURE' },
      },
    }, pipeline)
    local call = vim.fn.readfile(dir .. '/calls')[1]
    assert.is_nil(call:find('user-token', 1, true))
    assert.is_truthy(call:find('pipelineName: $job', 1, true))
    assert.is_truthy(
      call:find('-- https://acme.dagster.cloud/prod/graphql', 1, true)
    )
    assert.same(
      { 'Dagster-Cloud-Api-Token: user-token' },
      vim.fn.readfile(dir .. '/stdin')
    )
  end)

  it('says what Dagster answered instead of runs', function()
    cli('curl', {
      [[echo '{"errors":[{"message":"Unauthorized"}]}']],
    })
    assert.same(
      { nil, 'Dagster: Unauthorized' },
      await(function(cb) dagster.fetch(target, cb) end)
    )
    cli('curl', {
      [[echo '{"data":{"runsOrError":{"__typename":"Runs","results":[]}}}']],
    })
    assert.same(
      { nil, 'No run of job nightly' },
      await(function(cb) dagster.fetch(target, cb) end)
    )
  end)

  it('says when Dagster answers with no runs or no data', function()
    cli('curl', { [[echo '{"other":true}']] })
    assert.same(
      { nil, 'Dagster answered with no data' },
      await(function(cb) dagster.fetch(target, cb) end)
    )
    cli('curl', { [[echo '{"data":{}}']] })
    assert.same(
      { nil, 'Dagster answered with no runs' },
      await(function(cb) dagster.fetch(target, cb) end)
    )
    cli('curl', {
      [[echo '{"data":{"runsOrError":{"__typename":"PythonError","message":"boom"}}}']],
    })
    assert.same(
      { nil, 'Dagster: boom' },
      await(function(cb) dagster.fetch(target, cb) end)
    )
    -- An error without a message is named by its type
    cli('curl', {
      [[echo '{"data":{"runsOrError":{"__typename":"InvalidPipelineRunsFilterError"}}}']],
    })
    assert.same(
      { nil, 'Dagster: InvalidPipelineRunsFilterError' },
      await(function(cb) dagster.fetch(target, cb) end)
    )
  end)

  it('says why a run has no log', function()
    local function log()
      return await(
        function(cb)
          dagster.log(target, { id = 'gone' }, { id = 'x', name = 'x' }, 64, cb)
        end
      )
    end
    cli('curl', {
      [[echo '{"data":{"logsForRun":{"__typename":"RunNotFoundError","message":"Run gone not found"}}}']],
    })
    assert.same({ nil, false, 'Dagster: Run gone not found', false }, log())
    cli('curl', { [[echo '{"data":{}}']] })
    assert.same({ nil, false, 'Dagster: no log', false }, log())
  end)

  it('reads what a step logged, page after page', function()
    cli('curl', {
      'case "$*" in',
      [[  *'"cursor":"c1"'*) echo '{"data":{"logsForRun":{"__typename":"EventConnection","cursor":"c2","hasMore":false,"events":[{"__typename":"ExecutionStepFailureEvent","message":"Step failed","stepKey":"notify_team","error":{"message":"KeyError: x","stack":["  File a.py\n"]}}]}}}';;]],
      [[  *) echo '{"data":{"logsForRun":{"__typename":"EventConnection","cursor":"c1","hasMore":true,"events":[{"__typename":"LogMessageEvent","message":"other","stepKey":"raw_orders"},{"__typename":"LogMessageEvent","message":"sending","stepKey":"notify_team"}]}}}';;]],
      'esac',
    })
    local got = await(
      function(cb)
        dagster.log(
          target,
          { id = 'abc' },
          { id = 'notify_team', name = 'notify_team' },
          4096,
          cb
        )
      end
    )
    assert.same({
      'sending\nStep failed\nKeyError: x\n  File a.py',
      false,
      nil,
      false,
    }, got)
  end)
end)
