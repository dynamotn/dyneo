local h = require('helpers')

local GITLAB = {
  'stages: [build, test]',
  'variables:',
  '  A: 1',
  '.base: &base',
  '  image: alpine',
  'build:',
  '  <<: *base',
  '  script: make',
  '"unit tests": # quoted',
  '  script: make test',
  'deploy: &deploy',
  '  script: ./deploy',
  'include:',
  '  - local: x.yml',
}

local GITHUB = {
  'name: CI',
  'on: push',
  'jobs:',
  '  build:',
  '    name: Build it',
  '    runs-on: ubuntu-latest',
  '    strategy:',
  '      matrix:',
  '        os: [a, b]',
  '    steps:',
  '      - name: not a job',
  '        run: make',
  '# a comment at the start of a line',
  '  test:',
  '    runs-on: ubuntu-latest',
  '  call:',
  '    uses: ./.github/workflows/reuse.yml',
  'env:',
  '  notjob: 1',
}

local AZURE = {
  'trigger: [main]',
  'stages:',
  '  - stage: Build',
  '    displayName: Build stage',
  '    jobs:',
  '      - job: compile',
  '        displayName: "Compile it" # quoted',
  '        strategy:',
  '          matrix:',
  '            linux: {}',
  '        steps:',
  '          - script: make',
  '            displayName: not a job',
  '  - stage: Ship',
  '    jobs:',
  '      - deployment: release',
  '        environment: prod',
  '      # - job: commented',
}

describe('tools.ci_inline', function()
  local ci, dir, cleanup, notes, restore_notify

  before_each(function()
    h.unload('tools.ci_inline', 'util.forge')
    ci = require('tools.ci_inline')
    dir, cleanup = h.tmpdir()
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    restore_notify()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('buckets every status and conclusion, unknown ones pending', function()
    assert.equals('pass', ci.bucket('success'))
    assert.equals('fail', ci.bucket('completed', 'failure'))
    assert.equals('running', ci.bucket('in_progress', vim.NIL))
    assert.equals('skipped', ci.bucket('canceled'))
    assert.equals('pending', ci.bucket('something_new'))
    assert.equals('pending', ci.bucket(nil, nil))
  end)

  it(
    'finds the jobs of a .gitlab-ci.yml, templates and keywords left out',
    function()
      assert.same(
        { build = 6, ['unit tests'] = 9, deploy = 11 },
        ci.job_lines(GITLAB, 'gitlab')
      )
    end
  )

  it(
    'finds the jobs of a workflow, by id and by name',
    function()
      assert.same(
        { build = 4, ['Build it'] = 4, test = 14, call = 16 },
        ci.job_lines(GITHUB, 'github')
      )
    end
  )

  it('puts the loudest run of a job on its line, matrix and all', function()
    local lines = ci.job_lines(GITHUB, 'github')
    local marks = ci.marks({
      { name = 'Build it (a)', status = 'completed', conclusion = 'success' },
      { name = 'Build it (b)', status = 'completed', conclusion = 'failure' },
      { name = 'test', status = 'in_progress' },
      { name = 'call / inner', status = 'queued' },
      { name = 'gone', status = 'completed', conclusion = 'success' },
    }, lines)
    assert.same({
      { line = 4, bucket = 'fail', count = 2 },
      { line = 14, bucket = 'running', count = 1 },
      { line = 16, bucket = 'pending', count = 1 },
    }, marks)
    assert.equals('✗ fail ×2', ci.text(marks[1]))
    assert.equals('● running', ci.text(marks[2]))
  end)

  it('finds where a job of a matrix or a parallel run is defined', function()
    assert.equals('build', ci.defined_as('build (ubuntu, 22)'))
    assert.equals('call', ci.defined_as('call / inner'))
    assert.equals('rspec', ci.defined_as('rspec 1/3'))
    assert.equals('deploy', ci.defined_as('deploy: [aws, us-east-1]'))
    assert.equals('plain', ci.defined_as('plain'))
    local marks = ci.marks({
      { name = 'build 1/2', status = 'success' },
      { name = 'build 2/2', status = 'failed' },
    }, ci.job_lines(GITLAB, 'gitlab'))
    assert.same({ { line = 6, bucket = 'fail', count = 2 } }, marks)
  end)

  it('finds the jobs of an Azure pipeline, by name and display name', function()
    assert.same(
      { compile = 6, ['Compile it'] = 6, release = 16 },
      ci.job_lines(AZURE, 'azure')
    )
    -- A file of steps alone runs one job, called `Job`
    assert.same(
      { Job = 2 },
      ci.job_lines({ 'pool: x', 'steps:', '  - script: x' }, 'azure')
    )
    local marks = ci.marks({
      {
        name = 'Compile it linux',
        status = 'completed',
        conclusion = 'failed',
      },
      { name = 'release', status = 'inProgress' },
      { name = 'Job', status = 'completed', conclusion = 'succeeded' },
    }, ci.job_lines(AZURE, 'azure'), 'azure')
    assert.same({
      { line = 6, bucket = 'fail', count = 1 },
      { line = 16, bucket = 'running', count = 1 },
    }, marks)
    assert.equals('pass', ci.bucket('completed', 'succeededWithIssues'))
    assert.equals('attention', ci.bucket('partiallySucceeded'))
    assert.equals('pending', ci.bucket('notStarted'))
  end)

  it('reads the problems glab ci lint names', function()
    local diagnostics = ci.lint_diagnostics(
      table.concat({
        'Validating...',
        '.gitlab-ci.yml is invalid',
        '1 jobs:build config contains unknown keys: scritp',
        '2 root config contains unknown keys: stagez',
      }, '\n'),
      GITLAB
    )
    assert.equals(2, #diagnostics)
    assert.equals(5, diagnostics[1].lnum)
    assert.equals(
      'jobs:build config contains unknown keys: scritp',
      diagnostics[1].message
    )
    assert.equals(0, diagnostics[2].lnum)
    assert.same(
      {},
      ci.lint_diagnostics('Validating...\nCI/CD YAML is valid!', GITLAB)
    )
  end)

  describe('against a forge', function()
    local path, repo

    local function git(...)
      local result =
        vim.system(vim.list_extend({ 'git' }, { ... }), { cwd = repo }):wait()
      assert.equals(0, result.code, result.stderr)
    end

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

    before_each(function()
      repo = dir .. '/repo'
      vim.fn.mkdir(repo, 'p')
      git('init', '-q', '-b', 'feat/x')
      vim.fn.mkdir(dir .. '/bin', 'p')
      path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
    end)
    after_each(function() vim.env.PATH = path end)

    local function marks(bufnr)
      return vim.tbl_map(
        function(m) return { m[2], m[4].virt_text[1][1] } end,
        vim.api.nvim_buf_get_extmarks(
          bufnr,
          vim.api.nvim_create_namespace('dy_ci'),
          0,
          -1,
          { details = true }
        )
      )
    end

    it('shows the last GitLab pipeline of the branch on its jobs', function()
      git(
        'remote',
        'add',
        'origin',
        'git@gitlab.example.com:group/sub/proj.git'
      )
      cli('glab', {
        'case "$*" in',
        [[  *pipelines\?ref=*) echo '[{"id":42,"status":"failed","web_url":"https://x/42"}]';;]],
        [[  *pipelines/42/jobs*) echo '[{"name":"build","status":"failed"},{"name":"deploy","status":"manual"}]';;]],
        'esac',
      })
      h.write(repo .. '/.gitlab-ci.yml', GITLAB)
      vim.cmd.edit(repo .. '/.gitlab-ci.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.gitlab'
      ci.command({ fargs = {} })
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same(
        { { 5, '  ✗ fail' }, { 10, '  ○ pending' } },
        marks(bufnr)
      )
      assert.is_truthy(notes[1]:find('Pipeline 42 on feat/x', 1, true))

      local calls = vim.fn.readfile(dir .. '/calls')
      assert.equals(
        'api --hostname gitlab.example.com projects/group%2Fsub%2Fproj/pipelines?ref=feat%2Fx&per_page=1',
        calls[1]
      )
      ci.command({ fargs = { 'clear' } })
      assert.same({}, marks(bufnr))
    end)

    it('shows the last run of an Azure pipeline on its jobs', function()
      git(
        'remote',
        'add',
        'origin',
        'https://contoso@dev.azure.com/contoso/My%20Project/_git/web'
      )
      cli('az', {
        'case "$*" in',
        -- Only the spelling Azure kept the file under finds the pipeline
        [[  *yamlFilename=/azure-pipelines.yml*) echo '{"count":1,"value":[{"id":5,"name":"web-ci","repository":{"name":"web"},"process":{"yamlFilename":"/azure-pipelines.yml"}},{"id":6,"repository":{"name":"other"},"process":{"yamlFilename":"/azure-pipelines.yml"}}]}';;]],
        [[  *"--resource definitions"*) echo '{"count":0,"value":[]}';;]],
        [[  *"--resource builds"*) echo '{"count":1,"value":[{"id":77,"status":"completed","result":"failed","_links":{"web":{"href":"https://dev.azure.com/contoso/77"}}}]}';;]],
        [[  *"--resource timeline"*) echo '{"records":[{"type":"Stage","name":"Build"},{"type":"Job","name":"Compile it linux","state":"completed","result":"failed","log":{"id":9}},{"type":"Job","name":"release","state":"inProgress"}]}';;]],
        'esac',
      })
      h.write(repo .. '/azure-pipelines.yml', AZURE)
      vim.cmd.edit(repo .. '/azure-pipelines.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.az-pl'
      ci.status(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same(
        { { 5, '  ✗ fail' }, { 15, '  ● running' } },
        marks(bufnr)
      )
      assert.is_truthy(notes[1]:find('Run 77 on feat/x', 1, true))

      local calls = table.concat(vim.fn.readfile(dir .. '/calls'), '\n')
      assert.is_truthy(
        calls:find('--organization https://dev.azure.com/contoso', 1, true)
      )
      assert.is_truthy(calls:find('project=My Project', 1, true))
      assert.is_truthy(
        calls:find('branchName=refs/heads/feat/x definitions=5', 1, true)
      )
      assert.is_truthy(calls:find('buildId=77 project=My Project', 1, true))
    end)

    it('shows the last Jenkins build of the branch on its stages', function()
      git('config', 'dyneo.jenkinsJob', 'app/{branch}')
      git('config', 'dyneo.jenkinsUrl', 'https://ci.example.com')
      cli('curl', {
        'case "$*" in',
        [[  *job/app/job/feat%252Fx/lastBuild/api/json*) echo '{"number":5,"result":"FAILURE"}';;]],
        [[  */5/wfapi/describe*) echo '{"stages":[{"id":"1","name":"Build","status":"SUCCESS"},{"id":"2","name":"Test","status":"FAILED"}]}';;]],
        [[  *) exit 22;;]],
        'esac',
      })
      h.write(repo .. '/Jenkinsfile', {
        'pipeline {',
        '  stages {',
        "    stage('Build') { steps { sh 'make' } }",
        "    stage('Test') { steps { sh 'make test' } }",
        '  }',
        '}',
      })
      vim.cmd.edit(repo .. '/Jenkinsfile')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'groovy'
      ci.status(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same({ { 2, '  ✓ pass' }, { 3, '  ✗ fail' } }, marks(bufnr))
      assert.is_truthy(notes[1]:find('Build 5 on feat/x', 1, true))
      assert.is_truthy(
        notes[1]:find(
          'https://ci.example.com/job/app/job/feat%252Fx/5/',
          1,
          true
        )
      )
    end)

    it('shows the last run of the Airflow DAG under the cursor', function()
      h.globals()
      DyNeo.pipelines.airflow_api = 'v1'
      git('config', 'dyneo.airflowUrl', 'https://airflow.example.com')
      cli('curl', {
        'case "$*" in',
        [[  */dags/second/dagRuns\?order_by*) echo '{"dag_runs":[{"dag_run_id":"scheduled__1","state":"failed"}]}';;]],
        [[  */taskInstances\?*) echo '{"task_instances":[{"task_id":"b","state":"failed","try_number":1,"map_index":-1}],"total_entries":1}';;]],
        [[  *) exit 22;;]],
        'esac',
      })
      h.write(repo .. '/dags/etl.py', {
        'from airflow import DAG',
        'from airflow.operators.bash import BashOperator',
        'with DAG("first") as d1:',
        '    BashOperator(task_id="a", bash_command="true")',
        'with DAG("second") as d2:',
        '    BashOperator(task_id="b", bash_command="false")',
      })
      vim.cmd.edit(repo .. '/dags/etl.py')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'python'
      ci.attach(bufnr)
      -- Python's own `<localleader>s` stays the REPL's
      assert.equals(
        'Pipeline Status (CI)',
        vim.fn.maparg('<localleader>ps', 'n', false, true).desc
      )
      assert.equals('', vim.fn.maparg('<localleader>s', 'n'))
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      ci.status(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same({ { 5, '  ✗ fail' } }, marks(bufnr))
      assert.is_truthy(notes[1]:find('DAG run scheduled__1 on second', 1, true))
      assert.is_truthy(
        notes[1]:find(
          'https://airflow.example.com/dags/second/grid?dag_run_id=scheduled__1',
          1,
          true
        )
      )
    end)

    it('says when no Azure pipeline runs the file', function()
      git('remote', 'add', 'origin', 'git@ssh.dev.azure.com:v3/c/p/web')
      cli('az', { [[echo '{"count":0,"value":[]}']] })
      h.write(repo .. '/azure-pipelines.yml', AZURE)
      vim.cmd.edit(repo .. '/azure-pipelines.yml')
      vim.bo.filetype = 'yaml.az-pl'
      ci.status(0)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same({ 'No pipeline of p runs azure-pipelines.yml' }, notes)
    end)

    it('shows the last run of a GitHub workflow on its jobs', function()
      git('remote', 'add', 'gh', 'https://github.com/o/r.git')
      cli('gh', {
        'case "$*" in',
        [[  *workflows/ci.yml/runs*) echo '{"workflow_runs":[{"id":7,"status":"completed","conclusion":"success","html_url":"u"}]}';;]],
        [[  *runs/7/jobs*) echo '{"jobs":[{"name":"test","status":"completed","conclusion":"success"}]}';;]],
        'esac',
      })
      h.write(repo .. '/.github/workflows/ci.yml', GITHUB)
      vim.cmd.edit(repo .. '/.github/workflows/ci.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.gh-action'
      ci.status(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same({ { 13, '  ✓ pass' } }, marks(bufnr))
      assert.is_truthy(notes[1]:find('Run 7 on feat/x', 1, true))
    end)

    it('reads every page of jobs, not the first alone', function()
      git('remote', 'add', 'gh', 'https://github.com/o/r.git')
      cli('gh', {
        'case "$*" in',
        [[  *workflows/ci.yml/runs*) echo '{"workflow_runs":[{"id":7,"status":"completed","conclusion":"failure","html_url":"u"}]}';;]],
        [[  *runs/7/jobs*page=1) echo '{"jobs":[{"name":"other","status":"completed","conclusion":"success"}]}';;]],
        [[  *runs/7/jobs*page=2) echo '{"jobs":[{"name":"test","status":"completed","conclusion":"failure"}]}';;]],
        [[  *runs/7/jobs*) echo '{"jobs":[]}';;]],
        'esac',
      })
      ci.PER_PAGE = 1
      h.write(repo .. '/.github/workflows/ci.yml', GITHUB)
      vim.cmd.edit(repo .. '/.github/workflows/ci.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.gh-action'
      ci.status(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.same({ { 13, '  ✗ fail' } }, marks(bufnr))
    end)

    it('says when the forge has no pipeline, or is another one', function()
      git('remote', 'add', 'origin', 'https://gitlab.com/g/p')
      cli('glab', { [[echo '[]']] })
      h.write(repo .. '/.gitlab-ci.yml', GITLAB)
      vim.cmd.edit(repo .. '/.gitlab-ci.yml')
      vim.bo.filetype = 'yaml.gitlab'
      ci.status(0)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.equals('No pipeline on feat/x', notes[1])

      h.write(repo .. '/.github/workflows/ci.yml', GITHUB)
      vim.cmd.edit(repo .. '/.github/workflows/ci.yml')
      vim.bo.filetype = 'yaml.gh-action'
      ci.status(0)
      assert.is_true(vim.wait(5000, function() return #notes > 1 end, 20))
      assert.is_truthy(notes[2]:find('^No github remote'))
    end)

    it(
      'lints with GitLab only what may leave the machine, once saved',
      function()
        git('remote', 'add', 'origin', 'https://gitlab.com/g/p')
        cli(
          'glab',
          { 'echo "1 jobs:build config contains unknown keys: x"', 'exit 1' }
        )
        h.write(repo .. '/.gitlab-ci.yml', GITLAB)
        vim.cmd.edit(repo .. '/.gitlab-ci.yml')
        local bufnr = vim.api.nvim_get_current_buf()
        vim.bo.filetype = 'yaml.gitlab'

        require('util.sensitive').mark(bufnr, 'test')
        ci.lint(bufnr)
        assert.is_truthy(notes[1]:find('not sent to GitLab', 1, true))
        vim.b[bufnr].dy_sensitive = nil

        vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '# edit' })
        ci.lint(bufnr)
        assert.is_truthy(notes[2]:find('Write the file first', 1, true))
        vim.cmd('silent write')

        ci.lint(bufnr)
        assert.is_true(vim.wait(5000, function() return #notes > 2 end, 20))
        local diagnostics = vim.diagnostic.get(bufnr)
        assert.equals(1, #diagnostics)
        assert.equals(6, diagnostics[1].lnum)
        assert.equals('GitLab found 1 problems', notes[3])
        assert.equals(
          'ci lint ' .. repo .. '/.gitlab-ci.yml',
          vim.fn.readfile(dir .. '/calls')[1]
        )
      end
    )

    it('lints without the env token on a host it is not for', function()
      local saved = {}
      for _, var in ipairs({ 'GITLAB_TOKEN', 'GITLAB_HOST', 'GL_HOST' }) do
        saved[var] = vim.env[var]
      end
      vim.env.GITLAB_TOKEN, vim.env.GITLAB_HOST, vim.env.GL_HOST =
        'spec-token', nil, nil
      cli('glab', {
        'echo "token=${GITLAB_TOKEN-unset} home=${HOME:+set}" >> "'
          .. dir
          .. '/env"',
      })
      h.write(repo .. '/.gitlab-ci.yml', GITLAB)
      vim.cmd.edit(repo .. '/.gitlab-ci.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.gitlab'
      git('remote', 'add', 'origin', 'https://gitlab.attacker.example/g/p')
      ci.lint(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      git('remote', 'set-url', 'origin', 'https://gitlab.com/g/p')
      ci.lint(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 1 end, 20))
      for var, value in pairs(saved) do
        vim.env[var] = value
      end
      assert.same(
        { 'token=unset home=set', 'token=spec-token home=set' },
        vim.fn.readfile(dir .. '/env')
      )
    end)

    it('stops reading jobs past the last page it may ask for', function()
      git('remote', 'add', 'gh', 'https://github.com/o/r.git')
      cli('gh', {
        'case "$*" in',
        [[  *workflows/ci.yml/runs*) echo '{"workflow_runs":[{"id":7,"status":"completed","conclusion":"failure"}]}';;]],
        [[  *runs/7/jobs*) echo '{"jobs":[{"name":"test","status":"completed","conclusion":"failure"}]}';;]],
        'esac',
      })
      ci.PER_PAGE, ci.MAX_PAGES = 1, 2
      h.write(repo .. '/.github/workflows/ci.yml', GITHUB)
      vim.cmd.edit(repo .. '/.github/workflows/ci.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.gh-action'
      ci.status(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.equals('More than 2 jobs: not all of them could be read', notes[1])
      assert.same({}, marks(bufnr))
    end)

    it(
      'says when the workflow has no run, and when a run has no URL',
      function()
        git('remote', 'add', 'gh', 'https://github.com/o/r.git')
        cli('gh', {
          'case "$*" in',
          [[  *workflows/ci.yml/runs*) echo '{"workflow_runs":[]}';;]],
          [[  *workflows/other.yml/runs*) echo '{"workflow_runs":[{"id":8,"status":"completed","conclusion":"success"}]}';;]],
          [[  *runs/8/jobs*) echo '{"jobs":[]}';;]],
          'esac',
        })
        h.write(repo .. '/.github/workflows/ci.yml', GITHUB)
        vim.cmd.edit(repo .. '/.github/workflows/ci.yml')
        vim.bo.filetype = 'yaml.gh-action'
        ci.status(0)
        assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
        assert.equals('No run of this workflow on feat/x', notes[1])

        h.write(repo .. '/.github/workflows/other.yml', GITHUB)
        vim.cmd.edit(repo .. '/.github/workflows/other.yml')
        vim.bo.filetype = 'yaml.gh-action'
        ci.status(0)
        assert.is_true(vim.wait(5000, function() return #notes > 1 end, 20))
        assert.equals('✓ Run 8 on feat/x', notes[2])
      end
    )

    it('says what a pipeline file needs before asking the forge', function()
      assert.is_nil(ci.kind(h.buffer({ filetype = 'yaml' })))
      ci.status(h.buffer({ filetype = 'yaml', lines = GITLAB }))
      ci.status(h.buffer({ filetype = 'yaml.gitlab', lines = GITLAB }))
      assert.same({
        'Not a pipeline file of a CI or data pipeline DyNeo knows',
        'This buffer holds no file',
      }, notes)
    end)

    it('says when the repository is not on a branch', function()
      git('remote', 'add', 'origin', 'https://gitlab.com/g/p')
      h.write(repo .. '/.gitlab-ci.yml', GITLAB)
      git('add', '.')
      git(
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        'commit',
        '-qm',
        'x',
        '--no-verify'
      )
      git('checkout', '-q', '--detach')
      vim.cmd.edit(repo .. '/.gitlab-ci.yml')
      vim.bo.filetype = 'yaml.gitlab'
      ci.status(0)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      assert.equals('Not on a branch', notes[1])
    end)

    it('lints only a GitLab file, with glab installed', function()
      h.write(repo .. '/.github/workflows/ci.yml', GITHUB)
      vim.cmd.edit(repo .. '/.github/workflows/ci.yml')
      vim.bo.filetype = 'yaml.gh-action'
      ci.lint()
      assert.is_truthy(notes[1]:find('^GitLab checks %.gitlab%-ci%.yml'))

      h.write(repo .. '/.gitlab-ci.yml', GITLAB)
      vim.cmd.edit(repo .. '/.gitlab-ci.yml')
      vim.bo.filetype = 'yaml.gitlab'
      local restore = h.stub(vim.fn, 'executable', function() return 0 end)
      ci.lint(0)
      restore()
      assert.equals('glab is not installed', notes[2])
    end)

    it('shows what glab said when it names no line', function()
      git('remote', 'add', 'origin', 'https://gitlab.com/g/p')
      cli('glab', { 'echo "could not reach GitLab" >&2', 'exit 1' })
      h.write(repo .. '/.gitlab-ci.yml', GITLAB)
      vim.cmd.edit(repo .. '/.gitlab-ci.yml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo.filetype = 'yaml.gitlab'
      ci.lint(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 20))
      local diagnostics = vim.diagnostic.get(bufnr)
      assert.equals(1, #diagnostics)
      assert.equals(0, diagnostics[1].lnum)
      assert.equals('could not reach GitLab', diagnostics[1].message)
      assert.equals('GitLab found 1 problems', notes[1])
    end)

    it('refuses an unknown subcommand', function()
      ci.command({ fargs = { 'nope' } })
      assert.same({ 'Unknown subcommand: nope' }, notes)
    end)

    it('maps lint only on a GitLab file', function()
      local gitlab = h.buffer({ filetype = 'yaml.gitlab' })
      local github = h.buffer({ filetype = 'yaml.gh-action' })
      ci.attach(gitlab)
      ci.attach(github)
      vim.api.nvim_set_current_buf(gitlab)
      assert.equals(1, vim.fn.maparg('<localleader>l', 'n', false, true).buffer)
      vim.api.nvim_set_current_buf(github)
      assert.same({}, vim.fn.maparg('<localleader>l', 'n', false, true))
      assert.equals(1, vim.fn.maparg('<localleader>s', 'n', false, true).buffer)
    end)
  end)
end)
