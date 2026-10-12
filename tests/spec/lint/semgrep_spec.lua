local h = require('helpers')

describe('lint.linters.semgrep', function()
  local semgrep, dir, cleanup, notes, reads, verdict, restores

  before_each(function()
    h.unload('lint.linters.semgrep')
    semgrep = require('lint.linters.semgrep')
    dir, cleanup = h.tmpdir()
    notes, reads, verdict = {}, 0, ''
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(vim.secure, 'read', function()
        reads = reads + 1
        return verdict
      end),
    }
  end)
  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('stays off the network', function()
    assert.is_true(vim.list_contains(semgrep.args, '--metrics=off'))
    assert.is_true(vim.list_contains(semgrep.args, '--disable-version-check'))
    assert.is_false(vim.list_contains(semgrep.args, 'auto'))
  end)

  it('bounds the time and memory of a run', function()
    local args = table.concat(semgrep.args, ' ', 1, #semgrep.args - 1)
    assert.matches('%-%-timeout 5', args)
    assert.matches('%-%-max%-memory 1024', args)
  end)

  it('runs the rules only once they are trusted, asking once', function()
    h.write(dir .. '/.semgrep.yml', { 'rules: []' })
    h.write(dir .. '/main.py')
    vim.cmd.edit(dir .. '/main.py')
    verdict = nil
    assert.is_false(semgrep.condition())
    assert.is_false(semgrep.condition())
    assert.are.equal(1, reads)
    assert.are.equal(1, #notes)
    assert.matches('not trusted', notes[1])
  end)

  it('asks again about rules that changed', function()
    local rules = dir .. '/.semgrep.yml'
    h.write(rules, { 'rules: []' })
    h.write(dir .. '/main.py')
    vim.cmd.edit(dir .. '/main.py')
    assert.is_true(semgrep.condition())
    assert.is_true(semgrep.condition())
    assert.are.equal(1, reads)
    vim.uv.fs_utime(rules, 1, 1)
    verdict = nil
    assert.is_false(semgrep.condition())
    assert.are.equal(2, reads)
  end)

  it('leaves a buffer with unwritten edits alone', function()
    h.write(dir .. '/.semgrep.yml', { 'rules: []' })
    h.write(dir .. '/main.py')
    vim.cmd.edit(dir .. '/main.py')
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'x = 1' })
    assert.is_false(semgrep.condition())
    assert.are.equal(0, reads)
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
