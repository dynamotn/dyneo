local h = require('helpers')

local MANIFEST = {
  'apiVersion: apps/v1',
  'kind: Deployment',
  'metadata:',
  '  name: "web"',
  'spec:',
  '  template:',
  '    spec:',
  '      containers:',
  '        - name: app',
}

describe('policy linters', function()
  local dir, cleanup

  before_each(function()
    h.unload(
      'lint.linters.checkov',
      'lint.linters.kube_linter',
      'lint.linters.conftest',
      'tools.kube'
    )
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  describe('checkov', function()
    local linter
    before_each(function() linter = require('lint.linters.checkov') end)

    it('runs on the saved file, fetching nothing', function()
      assert.equals('checkov', linter.cmd)
      assert.is_false(linter.stdin)
      assert.is_true(linter.ignore_exitcode)
      assert.equals('-f', linter.args[#linter.args])
      assert.is_truthy(vim.list_contains(linter.args, '--skip-download'))
    end)

    it('reads one framework or several, failed checks only', function()
      local one = vim.json.encode({
        check_type = 'terraform',
        results = {
          passed_checks = { { check_id = 'CKV_AWS_1' } },
          failed_checks = {
            {
              check_id = 'CKV_AWS_20',
              check_name = 'S3 bucket is not public',
              file_line_range = { 3, 9 },
              severity = 'HIGH',
              guideline = 'https://docs/x',
            },
            {
              check_id = 'CKV_AWS_21',
              check_name = vim.NIL,
              file_line_range = vim.NIL,
              severity = vim.NIL,
            },
          },
        },
      })
      local diagnostics = linter.parser(one)
      assert.equals(2, #diagnostics)
      assert.same({
        lnum = 2,
        col = 0,
        end_lnum = 2,
        severity = vim.diagnostic.severity.ERROR,
        message = 'S3 bucket is not public (https://docs/x)',
        code = 'CKV_AWS_20',
        source = 'checkov',
        user_data = { lsp = { code = 'CKV_AWS_20' } },
      }, diagnostics[1])
      -- A null name, range and severity still make a diagnostic
      assert.equals('CKV_AWS_21', diagnostics[2].message)
      assert.equals(0, diagnostics[2].lnum)
      assert.equals(vim.diagnostic.severity.WARN, diagnostics[2].severity)

      local several = vim.json.encode({
        { results = { failed_checks = { { check_id = 'A' } } } },
        { results = { failed_checks = { { check_id = 'B' } } } },
      })
      assert.equals(2, #linter.parser(several))
    end)

    it('reports a run that gave no usable report', function()
      assert.same({ linter.unreadable }, linter.parser(nil))
      assert.same({ linter.unreadable }, linter.parser(''))
      assert.same({ linter.unreadable }, linter.parser('not json'))
      assert.same({}, linter.parser('{"passed": 0, "failed": 0}'))
      assert.same({}, linter.parser('[1, "x"]'))
    end)

    it('lints YAML only when it is a manifest', function()
      h.write(dir .. '/deploy.yaml', MANIFEST)
      h.write(dir .. '/ci.yaml', { 'stages:', '  - build' })
      vim.cmd.edit(dir .. '/deploy.yaml')
      vim.bo.filetype = 'yaml'
      assert.is_true(linter.condition())
      vim.cmd.edit(dir .. '/ci.yaml')
      vim.bo.filetype = 'yaml.gitlab'
      assert.is_false(linter.condition())
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'terraform' }))
      assert.is_true(linter.condition())
    end)

    it('leaves the values and the Chart.yaml of a chart alone', function()
      h.write(dir .. '/chart/Chart.yaml', { 'apiVersion: v2', 'name: web' })
      h.write(dir .. '/chart/values.yaml', { 'replicas: 2' })
      for _, file in ipairs({ 'Chart.yaml', 'values.yaml' }) do
        vim.cmd.edit(dir .. '/chart/' .. file)
        vim.bo.filetype = 'yaml'
        -- What the kube mappings are for, but no manifest to check
        assert.is_true(require('tools.kube').is_kube(0))
        assert.is_false(linter.condition(), file)
        assert.is_false(require('lint.linters.kube_linter').condition(), file)
      end
    end)
  end)

  describe('kube_linter', function()
    local linter
    before_each(function() linter = require('lint.linters.kube_linter') end)

    it('finds the line naming an object', function()
      assert.equals(3, linter.line_of(MANIFEST, 'web'))
      assert.equals(8, linter.line_of(MANIFEST, 'app'))
      assert.equals(0, linter.line_of(MANIFEST, 'missing'))
      assert.equals(0, linter.line_of(MANIFEST, nil))
    end)

    it('puts each report on its object', function()
      local bufnr = h.buffer({ lines = MANIFEST })
      local output = vim.json.encode({
        Reports = {
          {
            Check = 'no-read-only-root-fs',
            Diagnostic = { Message = 'container "app" has no read-only fs' },
            Remediation = 'Set readOnlyRootFilesystem',
            Object = { K8sObject = { Name = 'web' } },
          },
          { Check = 'latest-tag', Object = vim.NIL },
          { Object = {} },
        },
      })
      local diagnostics = linter.parser(output, bufnr)
      assert.equals(3, #diagnostics)
      assert.equals(3, diagnostics[1].lnum)
      assert.equals(
        'container "app" has no read-only fs\nSet readOnlyRootFilesystem',
        diagnostics[1].message
      )
      assert.equals('no-read-only-root-fs', diagnostics[1].code)
      assert.equals('latest-tag', diagnostics[2].message)
      assert.equals(0, diagnostics[2].lnum)
      assert.equals('kube-linter finding', diagnostics[3].message)
    end)

    it('reports a run that gave no usable report', function()
      assert.same({ linter.unreadable }, linter.parser(''))
      assert.same({ linter.unreadable }, linter.parser('nope'))
      assert.same({}, linter.parser('{"Reports": null}'))
    end)
  end)

  describe('conftest', function()
    local linter
    before_each(function() linter = require('lint.linters.conftest') end)

    it('finds the policies above the file, and lints only then', function()
      h.write(dir .. '/app/k8s/deploy.yaml', MANIFEST)
      h.write(dir .. '/other/deploy.yaml', MANIFEST)
      vim.fn.mkdir(dir .. '/app/policy', 'p')

      assert.equals(
        dir .. '/app/policy',
        linter.policy_dir(dir .. '/app/k8s/deploy.yaml')
      )
      assert.is_nil(linter.policy_dir(''))

      vim.cmd.edit(dir .. '/app/k8s/deploy.yaml')
      assert.is_true(linter.condition())
      assert.equals(dir .. '/app/policy', linter.args[#linter.args]())

      vim.cmd.edit(dir .. '/other/deploy.yaml')
      local outside = linter.policy_dir(dir .. '/other/deploy.yaml')
      -- Only a `policy/` above the scratch directory could answer here
      if outside == nil then assert.is_false(linter.condition()) end
    end)

    it('reads failures and warnings', function()
      local output = vim.json.encode({
        {
          filename = 'deploy.yaml',
          failures = {
            {
              msg = 'containers must not run as root',
              metadata = { query = 'data.main.deny' },
            },
          },
          warnings = { { msg = 'no team label' } },
          successes = 3,
        },
      })
      local diagnostics = linter.parser(output)
      assert.equals(2, #diagnostics)
      assert.equals(vim.diagnostic.severity.ERROR, diagnostics[1].severity)
      assert.equals('data.main.deny', diagnostics[1].code)
      assert.equals('containers must not run as root', diagnostics[1].message)
      assert.equals(vim.diagnostic.severity.WARN, diagnostics[2].severity)
      assert.same({}, linter.parser('{}'))
      assert.same({ linter.unreadable }, linter.parser(''))
    end)
  end)

  describe('config.languages', function()
    it('names the policy linters, actionlint for workflows only', function()
      h.globals()
      local yaml = require('config.languages').yaml
      local names, actionlint = {}, nil
      for _, tool in ipairs(yaml.linters) do
        local name = type(tool) == 'table' and tool[1] or tool
        names[name] = true
        if name == 'actionlint' then actionlint = tool end
      end
      assert.is_true(names.checkov and names.kube_linter and names.conftest)
      assert.is_truthy(actionlint)

      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'yaml.gh-action' }))
      assert.is_true(actionlint.opts.condition())
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'yaml.gitlab' }))
      assert.is_false(actionlint.opts.condition())
    end)
  end)
end)
