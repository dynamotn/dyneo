local h = require('helpers')

describe('tools.review.ci', function()
  local ci, dir, cleanup, path, restore

  before_each(function()
    h.unload(
      'tools.review.ci',
      'tools.review.panel',
      'util.forge',
      'tools.ci_jenkins',
      'tools.ci_argo'
    )
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(dir .. '/tree', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    restore = {}
    -- No Jenkins or Argo unless a test turns them on
    restore[#restore + 1] = h.stub(
      require('tools.ci_jenkins'),
      'target',
      function(_, _, cb) cb(nil, 'No Jenkins job: git config dyneo.jenkinsJob') end
    )
    ci = require('tools.review.ci')
  end)

  after_each(function()
    for _, undo in ipairs(restore) do
      undo()
    end
    vim.env.PATH = path
    cleanup()
  end)

  --- A fake CLI: it logs its arguments to `<name>.log` and prints the first
  --- answer whose pattern its arguments contain, else fails
  ---@param name string
  ---@param answers { [1]: string, [2]: table|string }[]
  local function fake(name, answers)
    local lines = {
      '#!/bin/sh',
      ('echo "$*" >> "%s/%s.log"'):format(dir, name),
      'case "$*" in',
    }
    for i, answer in ipairs(answers) do
      local file = ('%s/%s.%d.json'):format(dir, name, i)
      local body = type(answer[2]) == 'string' and answer[2]
        or vim.json.encode(answer[2])
      vim.fn.writefile({ body }, file)
      lines[#lines + 1] = ('  *%s*) cat "%s"; exit 0;;'):format(answer[1], file)
    end
    vim.list_extend(lines, { '  *) echo "boom" >&2; exit 1;;', 'esac' })
    h.write(dir .. '/bin/' .. name, lines)
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  --- What the fake `name` was called with
  ---@param name string
  ---@return string
  local function log(name)
    local file = ('%s/%s.log'):format(dir, name)
    return vim.uv.fs_stat(file) and table.concat(vim.fn.readfile(file), '\n')
      or ''
  end

  local SHA = 'abc123def456'

  local function session(kind, extra)
    local remotes = {
      github = { kind = 'github', host = 'github.com', slug = 'o/r' },
      gitlab = { kind = 'gitlab', host = 'gitlab.com', slug = 'g/p' },
      azure = {
        kind = 'azure',
        host = 'dev.azure.com',
        slug = 'org/proj/repo',
        org = 'org',
        project = 'proj',
        repo = 'repo',
      },
    }
    remotes[kind].name = 'origin'
    return vim.tbl_extend('force', {
      forge = kind,
      remote = remotes[kind],
      pull = { id = '7', head_sha = SHA, head_ref = 'feat/x' },
      worktree = dir .. '/tree',
      files = {},
    }, extra or {})
  end

  ---@return DyReviewCiRun[] runs
  ---@return string[] errors
  ---@return string[] waiting
  local function status(s)
    local done, runs, errors, waiting = false, nil, nil, nil
    ci.status(s, function(r, e, w)
      done, runs, errors, waiting = true, r, e, w
    end)
    assert.is_true(vim.wait(10000, function() return done end, 5))
    return runs, errors, waiting
  end

  it('asks GitHub for the checks of the head commit', function()
    fake('gh', {
      {
        'commits/' .. SHA .. '/check-runs',
        {
          total_count = 3,
          check_runs = {
            {
              name = 'build',
              status = 'completed',
              conclusion = 'success',
              html_url = 'https://github.com/o/r/runs/1',
            },
            { name = 'lint', status = 'completed', conclusion = 'failure' },
            { name = 'e2e', status = 'in_progress' },
          },
        },
      },
    })
    local runs, errors = status(session('github'))
    assert.same({}, errors)
    assert.is_truthy(
      log('gh'):find('commits/' .. SHA .. '/check-runs', 1, true)
    )
    assert.same(
      { 'pass', 'fail', 'running' },
      vim.tbl_map(function(r) return r.state end, runs)
    )
    assert.equals('commit', runs[1].by)
    assert.equals('github', runs[1].provider)
    -- The slug comes from a remote, and asks nothing else of the API
    local bent = session('github')
    bent.remote.slug = 'o/r?x='
    status(bent)
    assert.is_nil(log('gh'):find('r?x=', 1, true))
    assert.is_truthy(log('gh'):find('repos/o/r%3Fx%3D/commits/', 1, true))
    assert.equals('https://github.com/o/r/runs/1', runs[1].url)
  end)

  it('says when GitHub gave only some of the checks', function()
    fake('gh', {
      {
        'check-runs',
        {
          total_count = 120,
          check_runs = {
            { name = 'a', status = 'completed', conclusion = 'success' },
          },
        },
      },
    })
    local runs, errors = status(session('github'))
    assert.equals(1, #runs)
    assert.same({ 'github: only 1 of 120 checks were read' }, errors)
  end)

  it(
    'asks GitLab for the pipeline of the head commit, then its jobs',
    function()
      fake('glab', {
        {
          '/pipelines/9/jobs',
          { { id = 1, name = 'test', status = 'failed' } },
        },
        {
          'pipelines?sha=' .. SHA,
          { { id = 9, web_url = 'https://gitlab.com/g/p/-/pipelines/9' } },
        },
      })
      local runs, errors = status(session('gitlab'))
      assert.same({}, errors)
      assert.is_truthy(log('glab'):find('pipelines?sha=' .. SHA, 1, true))
      assert.equals(1, #runs)
      assert.equals('fail', runs[1].state)
      assert.equals('commit', runs[1].by)
      assert.equals('https://gitlab.com/g/p/-/pipelines/9', runs[1].url)
    end
  )

  it('says when GitLab has more jobs than one page holds', function()
    local jobs = {}
    for i = 1, 100 do
      jobs[i] = { id = i, name = 'job ' .. i, status = 'success' }
    end
    fake('glab', {
      { '/pipelines/9/jobs', jobs },
      { 'pipelines?sha=' .. SHA, { { id = 9 } } },
    })
    local runs, errors = status(session('gitlab'))
    assert.equals(100, #runs)
    assert.equals('pass', runs[100].state)
    assert.same({ 'gitlab: more than 100 jobs: not all were read' }, errors)
  end)

  it('shows no run, and no error, for a commit GitLab has not built', function()
    fake('glab', { { 'pipelines?sha=', '[]' } })
    local runs, errors = status(session('gitlab'))
    assert.same({}, runs)
    assert.same({}, errors)
  end)

  describe('Azure', function()
    it('takes the builds that ran the head by the commit', function()
      fake('az', {
        {
          'refs/pull/7/merge',
          {
            value = {
              {
                id = 2,
                status = 'completed',
                result = 'failed',
                sourceVersion = 'mergecommit',
                triggerInfo = { ['pr.sourceSha'] = SHA },
                definition = { id = 1, name = 'ci' },
                _links = { web = { href = 'https://dev.azure.com/org/b/2' } },
              },
              {
                id = 1,
                status = 'completed',
                result = 'succeeded',
                sourceVersion = 'older',
                definition = { id = 1, name = 'ci' },
              },
            },
          },
        },
      })
      local runs, errors = status(session('azure'))
      assert.same({}, errors)
      assert.equals(1, #runs)
      assert.equals('fail', runs[1].state)
      assert.equals('commit', runs[1].by)
      assert.equals('https://dev.azure.com/org/b/2', runs[1].url)
    end)

    it(
      'marks the newest builds as by branch when none names the head',
      function()
        fake('az', {
          {
            'refs/pull/7/merge',
            {
              value = {
                {
                  id = 2,
                  status = 'completed',
                  result = 'succeeded',
                  sourceVersion = 'mergecommit',
                  definition = { id = 1, name = 'ci' },
                },
              },
            },
          },
        })
        local runs = status(session('azure'))
        assert.equals('pass', runs[1].state)
        assert.equals('branch', runs[1].by)
      end
    )
  end)

  describe('Jenkins and Argo', function()
    it('ask Jenkins for the head branch, by branch', function()
      local asked
      restore[#restore + 1] = h.stub(
        require('tools.ci_jenkins'),
        'target',
        function(d, branch, cb)
          asked = { d, branch }
          cb({ base = 'https://jenkins.example/job/x' })
        end
      )
      restore[#restore + 1] = h.stub(
        require('tools.ci_jenkins'),
        'fetch',
        function(_, cb)
          cb({
            id = 5,
            status = 'FAILURE',
            url = 'https://jenkins.example/job/x/5/',
            jobs = {
              { id = 'a', name = 'Build', status = 'SUCCESS' },
              { id = 'b', name = 'Test', status = 'FAILURE' },
            },
          })
        end
      )
      fake('gh', { { 'check-runs', { total_count = 0, check_runs = {} } } })
      local runs, errors = status(session('github'))
      assert.same({ dir .. '/tree', 'feat/x' }, asked)
      assert.same({}, errors)
      assert.same(
        { 'pass', 'fail' },
        vim.tbl_map(function(r) return r.state end, runs)
      )
      assert.equals('branch', runs[1].by)
      assert.equals('jenkins', runs[1].provider)
      assert.equals('https://jenkins.example/job/x/5/', runs[1].url)
    end)

    it('report a failing Jenkins while the forge still shows', function()
      restore[#restore + 1] = h.stub(
        require('tools.ci_jenkins'),
        'target',
        function(_, _, cb) cb({ base = 'x' }) end
      )
      restore[#restore + 1] = h.stub(
        require('tools.ci_jenkins'),
        'fetch',
        function(_, cb) cb(nil, 'HTTP 403') end
      )
      fake('gh', {
        {
          'check-runs',
          {
            total_count = 1,
            check_runs = {
              { name = 'a', status = 'completed', conclusion = 'success' },
            },
          },
        },
      })
      local runs, errors = status(session('github'))
      assert.equals(1, #runs)
      assert.same({ 'jenkins: HTTP 403' }, errors)
    end)

    it('report a forge that cannot be asked, never a clean head', function()
      fake('gh', {})
      local runs, errors = status(session('github'))
      assert.same({}, runs)
      assert.equals(1, #errors)
      assert.is_truthy(errors[1]:find('^github: '))
    end)

    it('say a misconfigured Jenkins, but not an unconfigured one', function()
      restore[#restore + 1] = h.stub(
        require('tools.ci_jenkins'),
        'target',
        function(_, _, cb) cb(nil, 'Not a Jenkins URL: x') end
      )
      fake('gh', { { 'check-runs', { total_count = 0, check_runs = {} } } })
      local _, errors = status(session('github'))
      assert.same({ 'jenkins: Not a Jenkins URL: x' }, errors)
    end)

    it('ask Argo only for a workflow the pull request changes', function()
      local workflow = {
        'apiVersion: argoproj.io/v1alpha1',
        'kind: Workflow',
        'metadata:',
        '  name: nightly',
      }
      h.write(dir .. '/tree/ci/wf.yaml', workflow)
      h.write(dir .. '/tree/other.yaml', { 'a: 1' })
      local lines
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'target',
        function(_, l, cb)
          lines = l
          cb({ kind = 'Workflow', name = 'nightly' })
        end
      )
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'fetch',
        function(_, cb)
          cb({
            id = 'nightly',
            status = 'Running',
            jobs = {},
          })
        end
      )
      fake('gh', { { 'check-runs', { total_count = 0, check_runs = {} } } })
      local s = session('github', {
        trusted = true,
        files = {
          { path = 'other.yaml', blob = 'b0' },
          { path = 'ci/wf.yaml', blob = 'b1' },
        },
      })
      local runs = status(s)
      assert.same(workflow, vim.list_slice(lines, 1, 4))
      assert.equals('argo', runs[1].provider)
      assert.equals('running', runs[1].state)
      assert.equals('name', runs[1].by)
    end)

    local WORKFLOW = {
      'apiVersion: argoproj.io/v1alpha1',
      'kind: Workflow',
      'metadata:',
      '  name: nightly',
    }

    local function with_workflow(extra)
      h.write(dir .. '/tree/wf.yaml', WORKFLOW)
      fake('gh', { { 'check-runs', { total_count = 0, check_runs = {} } } })
      return session(
        'github',
        vim.tbl_extend('force', {
          files = { { path = 'wf.yaml', blob = 'b' } },
        }, extra or {})
      )
    end

    it('hold Argo back while the code is not trusted, and say so', function()
      local called = false
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'target',
        function() called = true end
      )
      local runs, errors, waiting = status(with_workflow())
      assert.is_false(called)
      assert.same({}, runs)
      assert.same({}, errors)
      assert.same({ 'argo: after you trust the PR' }, waiting)
    end)

    it('stop waiting for a source at its deadline', function()
      restore[#restore + 1] = h.stub(ci, 'SOURCE_TIMEOUT', 50)
      local late
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'target',
        function(_, _, cb) late = cb end
      )
      local runs, errors = status(with_workflow({ trusted = true }))
      -- The fake `gh` is held to the same short deadline, which a loaded
      -- machine may miss: only what Argo did is asked here
      errors = vim.tbl_filter(
        function(error) return not error:find('^github: ') end,
        errors
      )
      assert.same({ 'argo: timed out' }, errors)
      assert.same({}, runs)
      -- A reply after the deadline changes nothing and raises nothing
      late({ kind = 'Workflow', name = 'nightly' })
    end)

    it('take no run of the workflow for no runs, not a failure', function()
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'target',
        function(_, _, cb) cb({ kind = 'Workflow', name = 'nightly' }) end
      )
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'fetch',
        function(_, cb) cb(nil, 'No run of nightly in kind/default') end
      )
      local runs, errors = status(with_workflow({ trusted = true }))
      assert.same({}, runs)
      assert.same({}, errors)
    end)

    it('leave Argo alone when no workflow changes', function()
      local called = false
      restore[#restore + 1] = h.stub(
        require('tools.ci_argo'),
        'target',
        function() called = true end
      )
      fake('gh', { { 'check-runs', { total_count = 0, check_runs = {} } } })
      status(session('github', { files = { { path = 'a.lua', blob = 'b' } } }))
      assert.is_false(called)
    end)

    it('do not follow a link out of the worktree for a workflow', function()
      h.write(dir .. '/outside.yaml', {
        'apiVersion: argoproj.io/v1alpha1',
        'kind: Workflow',
      })
      vim.uv.fs_symlink(dir .. '/outside.yaml', dir .. '/tree/wf.yaml')
      local s = session('github', {
        files = { { path = 'wf.yaml', blob = 'b' } },
      })
      assert.is_nil(ci.argo_lines(s))
    end)
  end)

  describe('load', function()
    it('keeps the answer in the session and asks once at a time', function()
      fake('gh', {
        {
          'check-runs',
          {
            total_count = 1,
            check_runs = {
              { name = 'a', status = 'completed', conclusion = 'success' },
            },
          },
        },
      })
      local s = session('github')
      restore[#restore + 1] = h.stub(
        require('tools.review.session'),
        'current',
        function() return s end
      )
      ci.load(s)
      ci.load(s)
      assert.is_true(s.ci_loading)
      assert.is_true(vim.wait(10000, function() return s.ci ~= nil end, 5))
      assert.is_nil(s.ci_loading)
      assert.equals(1, #s.ci.runs)
      assert.equals(1, #vim.split(vim.trim(log('gh')), '\n'))
    end)

    it('drops an answer for a review that has closed', function()
      fake('gh', { { 'check-runs', { total_count = 0, check_runs = {} } } })
      local s = session('github')
      restore[#restore + 1] = h.stub(
        require('tools.review.session'),
        'current',
        function() return nil end
      )
      ci.load(s)
      assert.is_true(vim.wait(10000, function() return not s.ci_loading end, 5))
      assert.is_nil(s.ci)
    end)
  end)

  describe('pick', function()
    local opened, select

    before_each(function()
      opened = {}
      restore[#restore + 1] = h.stub(
        vim.ui,
        'open',
        function(url) opened[#opened + 1] = url end
      )
      restore[#restore + 1] = h.stub(vim.ui, 'select', function(items, opts, cb)
        select = { items = items, opts = opts }
        cb(items[select.choose or 1])
      end)
      select = nil
    end)

    it('opens the run chosen in the browser', function()
      local s = {
        ci = {
          runs = {
            {
              provider = 'github',
              name = 'a',
              state = 'pass',
              by = 'commit',
              url = 'https://x/1',
            },
            {
              provider = 'argo',
              name = 'b',
              state = 'fail',
              by = 'branch',
              url = 'https://x/2',
            },
          },
          errors = {},
        },
      }
      ci.pick(s)
      assert.equals(2, #select.items)
      assert.same({ 'https://x/1' }, opened)
      assert.equals('fail      b  (argo, by branch)', ci.label(s.ci.runs[2]))
    end)

    it('opens no link that is not a web one', function()
      ci.pick({
        ci = {
          runs = {
            {
              provider = 'github',
              name = 'a',
              state = 'pass',
              by = 'commit',
              url = 'file:///etc/passwd',
            },
          },
          errors = {},
        },
      })
      assert.same({}, opened)
    end)

    it('lists nothing when there is no run', function()
      ci.pick({ ci = { runs = {}, errors = {} } })
      assert.is_nil(select)
    end)
  end)
end)
