local h = require('helpers')

describe('lint.linters.semgrep', function()
  local semgrep, dir, cleanup

  before_each(function()
    h.unload('lint.linters.semgrep')
    semgrep = require('lint.linters.semgrep')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('stays off the network', function()
    assert.is_true(vim.list_contains(semgrep.args, '--metrics=off'))
    assert.is_true(vim.list_contains(semgrep.args, '--disable-version-check'))
    assert.is_false(vim.list_contains(semgrep.args, 'auto'))
  end)

  it('runs only in a project with rules of its own', function()
    h.write(dir .. '/app/main.py')
    vim.cmd.edit(dir .. '/app/main.py')
    assert.is_false(semgrep.condition())
    h.write(dir .. '/.semgrep.yml', { 'rules: []' })
    assert.is_true(semgrep.condition())
    assert.are.equal(dir .. '/.semgrep.yml', semgrep.args[#semgrep.args]())
  end)

  it('takes a folder of rules', function()
    h.write(dir .. '/.semgrep/a.yml', { 'rules: []' })
    h.write(dir .. '/main.go')
    vim.cmd.edit(dir .. '/main.go')
    assert.are.equal(dir .. '/.semgrep', semgrep.config(0))
  end)

  describe('parse', function()
    it('puts each result on its range', function()
      local d = semgrep.parse(vim.json.encode({
        results = {
          {
            check_id = 'rules.sqli',
            start = { line = 3, col = 5 },
            ['end'] = { line = 3, col = 20 },
            extra = { message = 'SQL injection', severity = 'ERROR' },
          },
        },
        errors = {},
      }))
      assert.are.equal(1, #d)
      assert.are.equal(2, d[1].lnum)
      assert.are.equal(4, d[1].col)
      assert.are.equal(19, d[1].end_col)
      assert.are.equal(vim.diagnostic.severity.ERROR, d[1].severity)
      assert.are.equal('rules.sqli', d[1].code)
      assert.are.equal('SQL injection', d[1].message)
    end)

    it('reports a rule error rather than a clean file', function()
      local d = semgrep.parse(vim.json.encode({
        results = {},
        errors = { { message = 'invalid rule' } },
      }))
      assert.are.equal(1, #d)
      assert.matches('invalid rule', d[1].message)
      assert.are.equal(vim.diagnostic.severity.ERROR, d[1].severity)
    end)

    it('reports output it cannot read', function()
      local d = semgrep.parse('Traceback ...')
      assert.are.equal(1, #d)
      assert.are.equal('semgrep-error', d[1].code)
    end)
  end)
end)
