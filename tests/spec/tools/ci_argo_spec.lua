local h = require('helpers')

local TEMPLATE = {
  'apiVersion: argoproj.io/v1alpha1',
  'kind: WorkflowTemplate',
  'metadata:',
  '  name: ci',
  '  namespace: builds',
  'spec:',
  '  entrypoint: main',
  '  arguments:',
  '    parameters:',
  '    - name: revision # not a step',
  '  templates:',
  '  - name: main',
  '    dag:',
  '      tasks:',
  '      - name: build',
  '        template: compile',
  '      - name: test',
  '        template: run-tests',
  '  - name: compile',
  '    container:',
  '      env:',
  '      - name: GOFLAGS',
  '        value: -mod=mod',
  '  - name: run-tests',
  '    steps:',
  '    - - name: unit',
  '        template: compile',
}

describe('tools.ci_argo', function()
  local argo, dir, cleanup, path, restore

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
    h.unload('tools.ci_argo', 'tools.kube')
    argo = require('tools.ci_argo')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    restore = h.stub(
      require('tools.kube'),
      'current',
      function(_, on_done) on_done('kind-dev', 'default') end
    )
  end)
  after_each(function()
    restore()
    vim.env.PATH = path
    cleanup()
  end)

  it('reads the kind, name and namespace of the first document', function()
    assert.same(
      { kind = 'WorkflowTemplate', name = 'ci', namespace = 'builds' },
      argo.read(TEMPLATE)
    )
    assert.same(
      { kind = 'Workflow', generate_name = 'nightly-' },
      argo.read({
        'kind: Workflow',
        'metadata:',
        '  generateName: "nightly-"',
        '  labels:',
        '    name: not-it',
      })
    )
  end)

  it(
    'finds templates, tasks and steps, not parameters or env',
    function()
      assert.same({
        main = 12,
        build = 15,
        test = 17,
        compile = 19,
        ['run-tests'] = 24,
        unit = 26,
      }, argo.job_lines(TEMPLATE))
    end
  )

  it('pins the context and the namespace it was shown', function()
    local got = await(function(cb) argo.target(dir, TEMPLATE, cb) end)
    assert.same({
      kind = 'WorkflowTemplate',
      name = 'ci',
      namespace = 'builds',
      context = 'kind-dev',
    }, got[1])
    assert.same({
      'kubectl',
      '--context',
      'kind-dev',
      '--namespace',
      'builds',
      '--request-timeout',
      '20s',
      'get',
      'pods',
    }, argo.kubectl(got[1], { 'get', 'pods' }))

    got = await(
      function(cb) argo.target(dir, { 'kind: WorkflowTemplate' }, cb) end
    )
    assert.same({ nil, 'This workflow has no name or generateName' }, got)
  end)

  local target = {
    kind = 'WorkflowTemplate',
    name = 'ci',
    namespace = 'builds',
    context = 'kind-dev',
  }

  it('shows the newest run of a template, by its label', function()
    cli('kubectl', {
      'case "$*" in',
      [[  *jsonpath*) printf 'ci-old\t2026-10-01T00:00:00Z\nci-new\t2026-10-18T09:00:00Z\n';;]],
      [[  *ci-new*) echo '{"metadata":{"name":"ci-new"},"status":{"phase":"Failed","nodes":{"ci-new":{"id":"ci-new","type":"DAG","phase":"Failed"},"n1":{"id":"n1","type":"Pod","displayName":"build","templateName":"compile","phase":"Succeeded"},"n2":{"id":"n2","type":"Pod","displayName":"unit(0)","templateName":"compile","phase":"Failed"}}}}';;]],
      'esac',
    })
    local pipeline = await(function(cb) argo.fetch(target, cb) end)[1]
    assert.same({
      id = 'ci-new',
      status = 'Failed',
      jobs = {
        {
          id = 'n1',
          name = 'build',
          template = 'compile',
          status = 'Succeeded',
        },
        {
          id = 'n2',
          name = 'unit(0)',
          template = 'compile',
          status = 'Failed',
        },
      },
    }, pipeline)
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.is_truthy(
      calls[1]:find(
        '--selector workflows.argoproj.io/workflow-template=ci',
        1,
        true
      )
    )
    assert.is_truthy(
      calls[2]:find(
        'get workflows.argoproj.io --output json -- ci-new',
        1,
        true
      )
    )

    -- Each run is marked on the step that ran it
    local ci = require('tools.ci_inline')
    assert.same({
      { line = 15, bucket = 'pass', count = 1 },
      { line = 26, bucket = 'fail', count = 1 },
    }, ci.marks(pipeline.jobs, argo.job_lines(TEMPLATE), 'argo'))
  end)

  it('takes the runs a generateName starts, and says when none ran', function()
    local wf = {
      kind = 'Workflow',
      generate_name = 'nightly-',
      namespace = 'n',
      context = 'c',
    }
    assert.equals(
      'nightly-b',
      argo.newest(wf, {
        { metadata = { name = 'nightly-a', creationTimestamp = '2026-01-01' } },
        { metadata = { name = 'nightly-b', creationTimestamp = '2026-02-01' } },
        { metadata = { name = 'other', creationTimestamp = '2026-03-01' } },
      })
    )
    cli('kubectl', { 'true' })
    local got = await(function(cb) argo.fetch(wf, cb) end)
    assert.same({ nil, 'No run of nightly- in c/n' }, got)
  end)

  it('reads the log of a step from its pod, its end only', function()
    argo.LOG_LINES = 2
    cli('kubectl', {
      'case "$*" in',
      [[  *"get pods"*) echo '{"items":[{"metadata":{"name":"ci-new-compile-1","annotations":{"workflows.argoproj.io/node-id":"n1"}}},{"metadata":{"name":"ci-new-compile-2","annotations":{"workflows.argoproj.io/node-id":"n2"}}}]}';;]],
      [[  *logs*) printf 'one\ntwo\nthree\n';;]],
      'esac',
    })
    local got = await(
      function(cb)
        argo.log(target, { id = 'ci-new' }, { id = 'n2', name = 'unit' }, cb)
      end
    )
    assert.same({ 'two\nthree\n', false, nil, true }, got)
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.is_truthy(
      calls[1]:find('--selector workflows.argoproj.io/workflow=ci-new', 1, true)
    )
    assert.is_truthy(
      calls[2]:find(
        'logs --container main --tail 3 -- ci-new-compile-2',
        1,
        true
      )
    )

    got = await(
      function(cb)
        argo.log(target, { id = 'ci-new' }, { id = 'gone', name = 'x' }, cb)
      end
    )
    assert.is_nil(got[1])
    assert.is_truthy(got[3]:find('The pod of x is gone', 1, true))
  end)
  it('never lets a manifest name reach kubectl as a flag', function()
    cli('kubectl', { 'exit 0' })
    local function target_of(name, namespace)
      local lines = { 'kind: Workflow', 'metadata:', '  name: ' .. name }
      if namespace then lines[#lines + 1] = '  namespace: ' .. namespace end
      return await(function(cb) argo.target(dir, lines, cb) end)
    end
    for _, bad in ipairs({
      '--server=https://x',
      '--kubeconfig=/tmp/k',
      'UPPER',
      '-lead',
      'trail-',
      ('a'):rep(254),
    }) do
      assert.same(
        { nil, 'This workflow names something Kubernetes could not' },
        target_of(bad)
      )
    end
    assert.same(
      { nil, 'This workflow names something Kubernetes could not' },
      target_of('ok', '--token=x')
    )
    assert.same(
      { nil, 'This workflow names something Kubernetes could not' },
      await(
        function(cb)
          argo.target(dir, {
            'kind: Workflow',
            'metadata:',
            '  generateName: --server=x',
          }, cb)
        end
      )
    )
    assert.equals('a.b-c', target_of('a.b-c', 'ns-1')[1].name)
    assert.is_nil(vim.uv.fs_stat(dir .. '/calls'))
  end)

  it('puts `--` before the name of a run, whatever it looks like', function()
    cli('kubectl', {
      'case "$*" in',
      [[  *jsonpath*) printf -- '--server=x\t2026-10-18T09:00:00Z\n';;]],
      'esac',
    })
    await(
      function(cb)
        argo.fetch({
          kind = 'WorkflowTemplate',
          name = 'ci',
          namespace = 'builds',
          context = 'kind-dev',
        }, cb)
      end
    )
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.is_truthy(calls[2]:find(' -- --server=x', 1, true))
  end)
end)
