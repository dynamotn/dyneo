local h = require('helpers')

describe('tools.kube', function()
  local kube, dir, cleanup

  before_each(function()
    h.unload('tools.kube')
    kube = require('tools.kube')
    dir, cleanup = h.tmpdir()
    h.write(dir .. '/app/deploy.yaml', {
      'apiVersion: apps/v1',
      'kind: Deployment',
      'metadata:',
      '  name: web',
    })
    h.write(dir .. '/app/kustomization.yaml', { 'resources: [deploy.yaml]' })
    h.write(dir .. '/chart/Chart.yaml', { 'name: web' })
    h.write(dir .. '/chart/values-prod.yaml', { 'replicas: 3' })
    h.write(dir .. '/chart/templates/svc.yaml', { 'kind: Service' })
    h.write(dir .. '/ci.yaml', { 'jobs:', '  build: {}' })
  end)
  after_each(function()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  describe('target', function()
    it('sends a manifest as it is, a kustomization as a directory', function()
      assert.same({
        kind = 'manifest',
        file = dir .. '/app/deploy.yaml',
        dir = dir .. '/app',
      }, kube.target(dir .. '/app/deploy.yaml'))
      assert.equals(
        'kustomize',
        kube.target(dir .. '/app/kustomization.yaml').kind
      )
      assert.same(
        { 'kubectl', 'diff', '-k', dir .. '/app' },
        kube.kubectl_command(
          { 'diff' },
          kube.target(dir .. '/app/kustomization.yaml')
        )
      )
    end)

    it(
      'renders a chart, with the values file or the template edited',
      function()
        local values = kube.target(dir .. '/chart/values-prod.yaml')
        assert.same({
          'helm',
          'template',
          'chart',
          dir .. '/chart',
          '--values',
          dir .. '/chart/values-prod.yaml',
        }, kube.render_command(values))
        local template = kube.target(dir .. '/chart/templates/svc.yaml')
        assert.same({
          'helm',
          'template',
          'chart',
          dir .. '/chart',
          '--show-only',
          'templates/svc.yaml',
        }, kube.render_command(template))
        assert.same(
          { 'kubectl', 'apply', '--dry-run=server', '-f', '-' },
          kube.kubectl_command({ 'apply', '--dry-run=server' }, values)
        )
      end
    )
  end)

  describe('field_at', function()
    local DEPLOY = {
      'apiVersion: v1',
      'kind: ConfigMap',
      '---',
      'apiVersion: "apps/v1"',
      'kind: Deployment',
      'metadata:',
      '  labels:',
      '    app.kubernetes.io/name: web # the app',
      'spec:',
      '  template:',
      '    spec:',
      '      containers:',
      '      - name: web',
      '        image: nginx',
      '        args:',
      '          - --port',
      '        ports:',
      '          - containerPort: 80',
      '            protocol: TCP',
      '      # a comment',
      '      restartPolicy: Always',
    }

    it('reads the keys down to the line, in its own document', function()
      local path, object = kube.field_at(DEPLOY, 14)
      assert.same({ 'spec', 'template', 'spec', 'containers', 'image' }, path)
      assert.same({ api_version = 'apps/v1', kind = 'Deployment' }, object)
      assert.same(
        { 'spec', 'template', 'spec', 'containers', 'ports', 'protocol' },
        (kube.field_at(DEPLOY, 19))
      )
      assert.same(
        { 'spec', 'template', 'spec', 'restartPolicy' },
        (kube.field_at(DEPLOY, 21))
      )
      assert.same({ 'kind' }, (kube.field_at(DEPLOY, 2)))
      assert.equals('ConfigMap', select(2, kube.field_at(DEPLOY, 1)).kind)
    end)

    it('puts a scalar item or a comment under the key above it', function()
      assert.same(
        { 'spec', 'template', 'spec', 'containers', 'args' },
        (kube.field_at(DEPLOY, 16))
      )
      assert.same({ 'spec', 'template', 'spec' }, (kube.field_at(DEPLOY, 20)))
      assert.same(
        { 'metadata', 'labels', 'app.kubernetes.io/name' },
        (kube.field_at(DEPLOY, 8))
      )
    end)
  end)

  it('maps only a buffer a cluster would take', function()
    local function has_maps(file)
      vim.cmd.edit(file)
      local bufnr = vim.api.nvim_get_current_buf()
      kube.attach(bufnr)
      for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, 'n')) do
        if map.desc == 'Diff With Cluster' then return true end
      end
      return false
    end
    assert.is_true(has_maps(dir .. '/app/deploy.yaml'))
    assert.is_true(has_maps(dir .. '/chart/values-prod.yaml'))
    assert.is_false(has_maps(dir .. '/ci.yaml'))
  end)

  describe('with a cluster', function()
    local path, notes, restore_notify, log

    --- A command that logs its arguments and stdin, prints `out`, exits `code`
    local function fake(name, out, code)
      h.write(dir .. '/bin/' .. name, {
        '#!/bin/sh',
        'echo "' .. name .. ' $*" >> "' .. log .. '"',
        'for last; do :; done',
        'if [ "$last" = "-" ]; then sed "s/^/stdin: /" >> "' .. log .. '"; fi',
        "printf '%s\\n' '" .. out .. "'",
        'exit ' .. code,
      })
      vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
    end

    local function logged() return vim.fn.readfile(log) end

    local function settle(n)
      assert.is_true(
        vim.wait(
          10000,
          function() return #notes >= n or vim.bo.filetype == 'diff' end,
          20
        )
      )
    end

    before_each(function()
      log = dir .. '/calls.log'
      vim.fn.mkdir(dir .. '/bin', 'p')
      path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      notes = {}
      restore_notify = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
    end)
    after_each(function()
      vim.env.PATH = path
      restore_notify()
    end)

    it('shows a diff, kept from every AI', function()
      fake('kubectl', '+  replicas: 3', 1)
      vim.cmd.edit(dir .. '/app/deploy.yaml')
      kube.diff()
      settle(1)
      assert.equals('diff', vim.bo.filetype)
      assert.same(
        { '+  replicas: 3' },
        vim.api.nvim_buf_get_lines(0, 0, -1, false)
      )
      assert.is_true(require('util.sensitive').is_sensitive(0))
      assert.same({ 'kubectl diff -f ' .. dir .. '/app/deploy.yaml' }, logged())
    end)

    it(
      'explains the field, or the one a key that is no field sits in',
      function()
        h.write(dir .. '/bin/kubectl', {
          '#!/bin/sh',
          'echo "kubectl $*" >> "' .. log .. '"',
          'case "$2" in',
          '  *.app) echo "field app does not exist" >&2; exit 1 ;;',
          '  *) echo "FIELD: $2" ;;',
          'esac',
        })
        vim.fn.setfperm(dir .. '/bin/kubectl', 'rwxr-xr-x')
        local shown
        local restore = h.stub(
          vim.lsp.util,
          'open_floating_preview',
          function(lines) shown = lines end
        )
        vim.api.nvim_set_current_buf(h.buffer({
          lines = {
            'apiVersion: apps/v1',
            'kind: Deployment',
            'metadata:',
            '  labels:',
            '    app: web',
          },
        }))
        vim.api.nvim_win_set_cursor(0, { 5, 4 })
        kube.explain()
        assert.is_true(vim.wait(10000, function() return shown ~= nil end, 20))
        restore()
        assert.same({
          '`app` is not a field of `deployment.metadata.labels`',
          '',
          'FIELD: deployment.metadata.labels',
        }, shown)
        assert.same({
          'kubectl explain deployment.metadata.labels.app --api-version=apps/v1',
          'kubectl explain deployment.metadata.labels --api-version=apps/v1',
        }, logged())
      end
    )

    it('says so when nothing differs', function()
      fake('kubectl', '', 0)
      vim.cmd.edit(dir .. '/app/deploy.yaml')
      kube.diff()
      settle(1)
      assert.equals('No differences with the cluster', notes[1])
    end)

    it('validates a chart by rendering it into kubectl', function()
      fake('helm', 'kind: Service', 0)
      fake('kubectl', 'service/web created (server dry run)', 0)
      vim.cmd.edit(dir .. '/chart/values-prod.yaml')
      kube.dry_run()
      settle(1)
      assert.equals('service/web created (server dry run)', notes[1])
      local calls = logged()
      assert.equals(
        'helm template chart '
          .. dir
          .. '/chart --values '
          .. dir
          .. '/chart/values-prod.yaml',
        calls[1]
      )
      assert.equals('kubectl apply --dry-run=server -f -', calls[2])
      assert.equals('stdin: kind: Service', calls[3])
    end)

    it('waits for every changed file a kustomization reads', function()
      fake('kubectl', '+  replicas: 3', 1)
      vim.cmd.edit(dir .. '/app/deploy.yaml')
      vim.api.nvim_buf_set_lines(0, 3, 4, false, { '  name: api' })
      vim.cmd.split(dir .. '/app/kustomization.yaml')
      kube.diff()
      assert.is_truthy(notes[1]:find('deploy.yaml first', 1, true))
      assert.equals(0, vim.fn.filereadable(log))
      -- A plain manifest elsewhere is not held back by it
      vim.cmd.edit(dir .. '/ci.yaml')
      kube.diff()
      settle(2)
      assert.equals(1, vim.fn.filereadable(log))
    end)

    it('sends nothing when the render was cut at the output cap', function()
      fake('helm', 'kind: Service', 0)
      fake('kubectl', 'service/web created (server dry run)', 0)
      local restore = h.stub(require('util.system'), 'MAX_BYTES', 4)
      vim.cmd.edit(dir .. '/chart/values-prod.yaml')
      kube.dry_run()
      settle(1)
      restore()
      assert.equals(
        'helm printed more than can be read, and was stopped',
        notes[1]
      )
      for _, call in ipairs(logged()) do
        assert.is_nil(call:find('kubectl', 1, true))
      end
    end)

    --- A kubectl whose context is `prod-cluster`, namespace `web`
    local function kubectl()
      h.write(dir .. '/bin/kubectl', {
        '#!/bin/sh',
        'echo "kubectl $*" >> "' .. log .. '"',
        'case "$*" in',
        [[  *jsonpath*) printf 'prod-cluster\tweb\n' ;;]],
        '  *) echo applied ;;',
        'esac',
      })
      vim.fn.setfperm(dir .. '/bin/kubectl', 'rwxr-xr-x')
    end

    it('applies only once told to, naming the context', function()
      kubectl()
      vim.cmd.edit(dir .. '/app/deploy.yaml')
      local asked
      local restore = h.stub(vim.fn, 'confirm', function(msg)
        asked = msg
        return 2
      end)
      kube.apply()
      -- The context is read off the main loop, then asked about
      assert.is_true(vim.wait(5000, function() return asked ~= nil end, 10))
      restore()
      assert.equals(
        'Apply deploy.yaml to context prod-cluster, namespace web by default?',
        asked
      )
      assert.is_nil(
        vim
          .iter(logged())
          :find(function(l) return l:find(' apply', 1, true) end)
      )
    end)

    it('applies to the context it named, whatever comes after', function()
      kubectl()
      vim.cmd.edit(dir .. '/app/deploy.yaml')
      local restore = h.stub(vim.fn, 'confirm', function() return 1 end)
      kube.apply()
      settle(1)
      restore()
      assert.equals(
        'kubectl --context=prod-cluster apply -f ' .. dir .. '/app/deploy.yaml',
        logged()[#logged()]
      )
    end)

    it('applies no chart with kubectl', function()
      kubectl()
      vim.cmd.edit(dir .. '/chart/templates/svc.yaml')
      kube.apply()
      assert.is_truthy(notes[1]:find('helm upgrade', 1, true))
      assert.equals(0, vim.fn.filereadable(log))
    end)

    it('acts on no buffer with changes not written', function()
      kubectl()
      vim.cmd.edit(dir .. '/app/deploy.yaml')
      vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'kind: Changed' })
      kube.diff()
      kube.apply()
      assert.is_truthy(notes[1]:find('Write the buffer first', 1, true))
      assert.equals(0, vim.fn.filereadable(log))
    end)
  end)
end)
