local h = require('helpers')

describe('util.ci_kind', function()
  local kind

  before_each(function()
    h.unload('util.ci_kind')
    kind = require('util.ci_kind')
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  it('tells each forge by its filetype', function()
    assert.equals('gitlab', kind.of(h.buffer({ filetype = 'yaml.gitlab' })))
    assert.equals('github', kind.of(h.buffer({ filetype = 'yaml.gh-action' })))
    assert.equals('azure', kind.of(h.buffer({ filetype = 'yaml.az-pl' })))
    assert.is_nil(kind.of(h.buffer({ filetype = 'lua' })))
  end)

  it('tells a Jenkinsfile from any other Groovy file', function()
    for _, name in ipairs({ 'Jenkinsfile', 'Jenkinsfile.ci', 'x.jenkinsfile' }) do
      local bufnr = h.buffer({ name = '/p/' .. name, filetype = 'groovy' })
      assert.equals('jenkins', kind.of(bufnr), name)
    end
    assert.is_nil(
      kind.of(h.buffer({ name = '/p/build.groovy', filetype = 'groovy' }))
    )
  end)

  it('tells an Argo workflow by its first document', function()
    local function of(lines)
      return kind.of(h.buffer({ filetype = 'yaml', lines = lines }))
    end
    assert.equals(
      'argo',
      of({ '---', 'apiVersion: argoproj.io/v1alpha1', 'kind: WorkflowTemplate' })
    )
    assert.equals(
      'argo',
      of({ 'kind: "CronWorkflow"', "apiVersion: 'argoproj.io/v1alpha1'" })
    )
    -- Argo CD's kinds are no workflow, nor is anything after the first
    assert.is_nil(
      of({ 'apiVersion: argoproj.io/v1alpha1', 'kind: Application' })
    )
    assert.is_nil(of({
      'apiVersion: v1',
      'kind: ConfigMap',
      '---',
      'apiVersion: argoproj.io/v1alpha1',
      'kind: Workflow',
    }))
    assert.is_nil(of({ 'apiVersion: batch/v1', 'kind: Workflow' }))
  end)

  it('tells a data pipeline by what its Python imports', function()
    local function of(lines)
      return kind.of(h.buffer({ filetype = 'python', lines = lines }))
    end
    assert.equals('airflow', of({ '"""ETL"""', 'from airflow.sdk import dag' }))
    assert.equals('prefect', of({ 'import prefect' }))
    assert.equals('dagster', of({ 'import dagster as dg' }))
    assert.is_nil(of({ 'import os', 'from prefecture import x' }))
  end)
end)
