local h = require('helpers')

describe('tools.ci_jenkins', function()
  local jenkins, dir, cleanup, path

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

  local function git(...)
    local result =
      vim.system(vim.list_extend({ 'git' }, { ... }), { cwd = dir }):wait()
    assert.equals(0, result.code, result.stderr)
  end

  --- What an asynchronous call hands back, waited for
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
    h.unload('tools.ci_jenkins', 'util.forge')
    jenkins = require('tools.ci_jenkins')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
  end)
  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  it('names a job in its folders, and a branch as multibranch does', function()
    assert.equals(
      'https://ci.x/job/team/job/app/job/feature%252Fa%20b',
      jenkins.job_url('https://ci.x/', 'team/app/{branch}', 'feature/a b')
    )
    assert.equals(
      'https://ci.x/job/nightly',
      jenkins.job_url('https://ci.x', 'nightly', 'main')
    )
  end)

  it('takes the server and the job from the clone, never the tree', function()
    git('init', '-q')
    local got = await(function(cb) jenkins.target(dir, 'main', cb) end)
    assert.is_nil(got[1])
    assert.is_truthy(got[2]:find('dyneo.jenkinsJob', 1, true))

    git('config', 'dyneo.jenkinsJob', 'team/app/{branch}')
    got = await(function(cb) jenkins.target(dir, 'main', cb) end)
    assert.is_truthy(got[2]:find('No Jenkins server', 1, true))

    DyNeo.jenkins.url = 'https://default.example'
    got = await(function(cb) jenkins.target(dir, 'main', cb) end)
    assert.equals(
      'https://default.example/job/team/job/app/job/main',
      got[1].base
    )

    git('config', 'dyneo.jenkinsUrl', 'https://ci.example.com/')
    got = await(function(cb) jenkins.target(dir, 'main', cb) end)
    assert.same({
      url = 'https://ci.example.com',
      job = 'team/app/{branch}',
      base = 'https://ci.example.com/job/team/job/app/job/main',
    }, got[1])

    git('config', 'dyneo.jenkinsUrl', 'file:///etc/passwd')
    got = await(function(cb) jenkins.target(dir, 'main', cb) end)
    assert.equals('Not a Jenkins URL: file:///etc/passwd', got[2])
  end)

  local target = {
    url = 'https://ci.x',
    job = 'app/{branch}',
    base = 'https://ci.x/job/app/job/main',
  }

  it('reads the last build and its stages', function()
    cli('curl', {
      'case "$*" in',
      [[  *lastBuild/api/json*) echo '{"number":12,"result":"FAILURE","building":false,"url":"https://other.host/12/"}';;]],
      [[  */12/wfapi/describe*) echo '{"id":"12","status":"FAILED","stages":[{"id":"6","name":"Build","status":"SUCCESS"},{"id":"9","name":"Test","status":"FAILED"}]}';;]],
      'esac',
    })
    local got = await(function(cb) jenkins.fetch(target, cb) end)
    assert.same({
      id = 12,
      status = 'FAILURE',
      -- Built from the job, not from the host the server names
      url = 'https://ci.x/job/app/job/main/12/',
      jobs = {
        { id = '6', name = 'Build', status = 'SUCCESS' },
        { id = '9', name = 'Test', status = 'FAILED' },
      },
    }, got[1])
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.is_truthy(calls[1]:find('--netrc-optional', 1, true))
    assert.is_truthy(calls[1]:find('--proto =https,http', 1, true))
  end)

  it(
    'says why there are no stages, and keeps the build to ask about',
    function()
      cli('curl', {
        'case "$*" in',
        [[  *lastBuild/api/json*) echo '{"number":3,"building":true}';;]],
        [[  *) echo 'curl: (22) The requested URL returned error: 404' >&2; exit 22;;]],
        'esac',
      })
      local pipeline = await(function(cb) jenkins.fetch(target, cb) end)[1]
      assert.equals('in_progress', pipeline.status)
      assert.same(
        { { id = 'build', name = '#3', status = 'in_progress' } },
        pipeline.jobs
      )
      assert.is_truthy(pipeline.note:find('404', 1, true))
    end
  )

  it('says when the job has no build', function()
    cli('curl', {
      [[echo 'curl: (22) The requested URL returned error: 404' >&2]],
      'exit 22',
    })
    local got = await(function(cb) jenkins.fetch(target, cb) end)
    assert.same({ nil, 'No build of https://ci.x/job/app/job/main' }, got)
  end)

  it(
    'finds the stages of a Jenkinsfile',
    function()
      assert.same(
        { Build = 3, ['Unit tests'] = 5, Deploy = 7 },
        jenkins.job_lines({
          'pipeline {',
          '  stages {',
          "    stage('Build') {",
          '    }',
          '    stage ( "Unit tests" ) {',
          '    }',
          "    stage('Deploy') { steps { sh 'x' } }",
        })
      )
    end
  )

  it('reads the end of a console, saying when its start is left out', function()
    cli('curl', { 'printf "one\\ntwo\\nthree\\n"' })
    local got = await(
      function(cb) jenkins.log(target, { id = 12, jobs = {} }, 6, cb) end
    )
    assert.same({ 'three\n', false, nil, true }, got)
    got = await(
      function(cb) jenkins.log(target, { id = 12, jobs = {} }, 64, cb) end
    )
    assert.same({ 'one\ntwo\nthree\n', false, nil, false }, got)
    assert.is_truthy(
      vim.fn
        .readfile(dir .. '/calls')[1]
        :find('-- https://ci.x/job/app/job/main/12/consoleText', 1, true)
    )

    cli('curl', { 'echo "curl: (7) Failed to connect" >&2', 'exit 7' })
    got = await(
      function(cb) jenkins.log(target, { id = 12, jobs = {} }, 64, cb) end
    )
    assert.is_nil(got[1])
    assert.is_truthy(got[3]:find('Failed to connect', 1, true))
  end)

  it('has the server check a Jenkinsfile sent on its input', function()
    cli('curl', {
      'cat > "' .. dir .. '/sent"',
      'echo "Errors encountered validating Jenkinsfile:"',
      [[echo "WorkflowScript: 4: Unknown stage section \"step\". @ line 4, column 9."]],
    })
    local got = await(
      function(cb) jenkins.lint('https://ci.x', 'pipeline {}\n', cb) end
    )
    assert.same({
      {
        lnum = 3,
        col = 8,
        message = 'Unknown stage section "step".',
        severity = vim.diagnostic.severity.ERROR,
        source = 'jenkins validate',
      },
    }, got[1])
    assert.same({ 'pipeline {}' }, vim.fn.readfile(dir .. '/sent'))
    local call = vim.fn.readfile(dir .. '/calls')[1]
    assert.is_truthy(call:find('jenkinsfile=<-', 1, true))
    assert.is_truthy(
      call:find('-- https://ci.x/pipeline-model-converter/validate', 1, true)
    )
    assert.is_nil(
      jenkins.lint_diagnostics('Jenkinsfile successfully validated.\n')
    )
  end)
end)
