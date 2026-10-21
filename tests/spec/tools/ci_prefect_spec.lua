local h = require('helpers')

local FLOW = {
  'from prefect import flow, task',
  '',
  '@task',
  'def extract():',
  '    return [1]',
  '',
  '@task(name="load-rows", retries=2)',
  'def load(rows):',
  '    pass',
  '',
  '@flow',
  'def daily_etl():',
  '    load(extract())',
}

describe('tools.ci_prefect', function()
  local prefect, dir, cleanup, path, bin

  --- A Python that answers as the client's side would, after noting how it
  --- was called
  local function python(lines)
    h.write(
      bin .. '/python',
      vim.list_extend({
        '#!/bin/sh',
        'shift 3',
        'echo "$@" >> "' .. dir .. '/calls"',
        'pwd >> "' .. dir .. '/calls"',
        'echo "ephemeral=$PREFECT_SERVER_ALLOW_EPHEMERAL_MODE" >> "'
          .. dir
          .. '/calls"',
      }, lines)
    )
    vim.fn.setfperm(bin .. '/python', 'rwxr-xr-x')
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
    h.unload('tools.ci_prefect', 'util.py_defs')
    prefect = require('tools.ci_prefect')
    dir, cleanup = h.tmpdir()
    bin = dir .. '/venv/bin'
    h.write(bin .. '/prefect', { '#!/bin/sh' })
    vim.fn.setfperm(bin .. '/prefect', 'rwxr-xr-x')
    path = vim.env.PATH
    vim.env.PATH = bin .. ':' .. path
  end)
  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  it('names flows and tasks as Prefect does', function()
    assert.same({ { id = 'daily-etl', line = 11 } }, prefect.flows(FLOW))
    assert.same(
      { extract = 3, ['load-rows'] = 7, ['daily-etl'] = 11 },
      prefect.job_lines(FLOW)
    )
  end)

  it('runs the Python beside prefect, or a trusted project venv', function()
    python({})
    assert.equals(bin .. '/python', prefect.python(nil))
    vim.env.PATH = path
    local venv = dir .. '/project/.venv/bin'
    for _, name in ipairs({ 'prefect', 'python' }) do
      h.write(venv .. '/' .. name, { '#!/bin/sh' })
      vim.fn.setfperm(venv .. '/' .. name, 'rwxr-xr-x')
    end
    local asked = {}
    local trusted = false
    local restore = h.stub(require('util.trust'), 'ask', function(purpose, root)
      table.insert(asked, { purpose, root })
      return trusted
    end)
    vim.env.PATH = bin .. ':' .. path
    assert.equals(bin .. '/python', prefect.python(dir .. '/project'))
    vim.env.PATH = path
    trusted = true
    assert.equals(venv .. '/python', prefect.python(dir .. '/project'))
    restore()
    assert.same({
      { 'prefect', dir .. '/project' },
      { 'prefect', dir .. '/project' },
    }, asked)
    local none, err = prefect.python(dir .. '/elsewhere')
    if vim.fn.exepath('prefect') == '' then
      assert.is_nil(none)
      assert.is_truthy(err:find('not installed', 1, true))
    end
  end)

  it('reads the last run that ran, away from the tree', function()
    python({
      [[echo '{"run":{"id":"r1","name":"brave-fox","state":"FAILED","url":"https://app.prefect.cloud/r1"},"tasks":[{"id":"t1","name":"extract-0","state":"COMPLETED"},{"id":"t2","name":"load-rows-0","state":"FAILED"}]}']],
    })
    local target = { flow = 'daily-etl', python = bin .. '/python' }
    local pipeline = await(function(cb) prefect.fetch(target, cb) end)[1]
    assert.same({
      id = 'brave-fox',
      run_id = 'r1',
      status = 'FAILED',
      url = 'https://app.prefect.cloud/r1',
      jobs = {
        { id = '', name = 'daily-etl', status = 'FAILED' },
        { id = 't1', name = 'extract-0', status = 'COMPLETED' },
        { id = 't2', name = 'load-rows-0', status = 'FAILED' },
      },
    }, pipeline)
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.equals('runs daily-etl 10 500', calls[1])
    assert.equals(vim.fn.stdpath('cache'), calls[2])
    assert.equals('ephemeral=false', calls[3])

    local ci = require('tools.ci_inline')
    assert.same({
      { line = 3, bucket = 'pass', count = 1 },
      { line = 7, bucket = 'fail', count = 1 },
      { line = 11, bucket = 'fail', count = 1 },
    }, ci.marks(pipeline.jobs, prefect.job_lines(FLOW), 'prefect'))
  end)

  it('says why the client gave nothing', function()
    python({ [[echo '{"run":null}']] })
    local target = { flow = 'daily-etl', python = bin .. '/python' }
    assert.same(
      { nil, 'No run of flow daily-etl' },
      await(function(cb) prefect.fetch(target, cb) end)
    )
    python({
      'echo "Traceback (most recent call last):" >&2',
      'echo "RuntimeError: No Prefect API URL provided" >&2',
      'exit 1',
    })
    assert.same(
      { nil, 'RuntimeError: No Prefect API URL provided' },
      await(function(cb) prefect.fetch(target, cb) end)
    )
  end)

  it('reads the log of a task run, or of the whole flow run', function()
    python({ 'printf "Starting\\nBoom\\n"' })
    local target = { flow = 'daily-etl', python = bin .. '/python' }
    local got = await(
      function(cb)
        prefect.log(
          target,
          { id = 'brave-fox', run_id = 'r1' },
          { id = 't2' },
          cb
        )
      end
    )
    assert.same({ 'Starting\nBoom\n', false, nil, false }, got)
    assert.equals('logs r1 t2 5000', vim.fn.readfile(dir .. '/calls')[1])
  end)
end)
