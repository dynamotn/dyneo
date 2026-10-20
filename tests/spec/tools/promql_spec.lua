local h = require('helpers')

local RULES = {
  'groups:',
  '  - name: api',
  '    rules:',
  '      - alert: HighErrors',
  '        expr: |',
  '          sum(rate(http_errors_total[5m]))',
  '            / sum(rate(http_requests_total[5m])) > 0.05',
  '        for: 10m',
  '        labels:',
  '          severity: page',
  '      - record: job:up:sum',
  "        expr: 'sum by (job) (up)'",
}

describe('tools.promql', function()
  local promql, dir, cleanup, path, notes, restore_notify, restore_globals

  before_each(function()
    h.unload('tools.promql', 'util.ci_http')
    promql = require('tools.promql')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    restore_globals =
      h.stub(_G, 'DyNeo', { prometheus = { url = 'https://prom.example/' } })
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    restore_globals()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  describe('the expression under the cursor', function()
    it('is the block expr of the rule the cursor is in', function()
      local expected = 'sum(rate(http_errors_total[5m]))\n'
        .. '  / sum(rate(http_requests_total[5m])) > 0.05'
      for _, row in ipairs({ 4, 6, 8, 10 }) do
        assert.equals(expected, promql.expression(RULES, row), row)
      end
      local _, first, last = promql.expression(RULES, 4)
      assert.same({ 5, 7 }, { first, last })
    end)

    it('is the quoted expr of the next rule, unquoted', function()
      assert.equals('sum by (job) (up)', promql.expression(RULES, 11))
      assert.equals('sum by (job) (up)', promql.expression(RULES, 12))
    end)

    it('reads every way YAML writes a scalar', function()
      local function expr(line, more)
        local lines = vim.list_extend({ '- alert: A', line }, more or {})
        return promql.expression(lines, 1)
      end
      assert.equals('rate(a[5m])', expr('  expr: "rate(a[5m])"  # per second'))
      assert.equals('rate(a[5m])', expr("  expr: 'rate(a[5m])' # per second"))
      assert.equals(
        'sum(rate(e[5m])) / sum(rate(r[5m])) > 0.05',
        expr('  expr: sum(rate(e[5m]))', {
          '    / sum(rate(r[5m])) > 0.05',
          '  for: 5m',
        })
      )
      assert.equals(
        'sum(x) > 1',
        expr('  expr: >- # folded', { '    sum(x)', '    > 1', '  for: 5m' })
      )
      assert.equals('up == 0', expr('  expr: |2', { '    up == 0' }))
    end)

    it('finds the rule from a list in its annotations', function()
      local lines = {
        'groups:',
        '  - name: g',
        '    rules:',
        '      - alert: A',
        '        expr: up == 0',
        '        annotations:',
        '          runbooks:',
        '            - https://example.com/a',
      }
      assert.equals('up == 0', promql.expression(lines, 8))
    end)

    it(
      'is the "expr" of a dashboard panel',
      function()
        assert.equals(
          'rate(x_total{job="a"}[5m])',
          promql.expression({
            '{',
            '  "targets": [',
            '    {',
            [[      "expr": "rate(x_total{job=\"a\"}[5m])",]],
            '      "refId": "A"',
          }, 5)
        )
      end
    )

    it('is the paragraph of a .promql file, comments left out', function()
      local lines = { '# errors', 'sum(rate(e[5m]))', '  by (job)', '', 'up' }
      assert.equals(
        'sum(rate(e[5m]))\n  by (job)',
        promql.expression(lines, 2, 'promql')
      )
      assert.equals('up', promql.expression(lines, 5, 'promql'))
      assert.is_nil(promql.expression(lines, 4, 'promql'))
      assert.is_nil(promql.expression({ 'plain text' }, 1, 'yaml'))
    end)
  end)

  it('writes labels and draws a sparkline', function()
    assert.equals(
      'up{instance="a:9100", job="node"}',
      promql.labels({ __name__ = 'up', job = 'node', instance = 'a:9100' })
    )
    assert.equals('{}', promql.labels({}))
    assert.equals('▁▅█', promql.spark({ 0, 5, 10 }))
    assert.equals('▄▄', promql.spark({ 3, 3 }))
    assert.equals('▁ █', promql.spark({ 1, 0 / 0, 2 }))
  end)

  it('reports each series with its value and its hour', function()
    local lines = promql.report('up', {
      resultType = 'vector',
      result = {
        { metric = { __name__ = 'up', job = 'a' }, value = { 1, '1' } },
        { metric = { __name__ = 'up', job = 'b' }, value = { 1, '0' } },
      },
    }, {
      resultType = 'matrix',
      result = {
        {
          metric = { __name__ = 'up', job = 'a' },
          values = { { 1, '0' }, { 2, '1' } },
        },
      },
    })
    local text = table.concat(lines, '\n')
    assert.is_truthy(text:find('2 series, the last 60 minutes drawn', 1, true))
    assert.is_truthy(text:find('- `up{job="a"}` **1** ▁█', 1, true))
    -- No history of it: no sparkline, and no space for one
    assert.is_truthy(vim.tbl_contains(lines, '- `up{job="b"}` **0**'))
    local scalar =
      promql.report('1+1', { resultType = 'scalar', result = { 1, '2' } })
    assert.equals('scalar: 2', scalar[#scalar])
    local none = promql.report('x', { resultType = 'vector', result = {} })
    assert.is_truthy(none[#none]:find('matched nothing', 1, true))
  end)

  --- A fake curl answering the instant and range queries with `instant` and
  --- `range`, its arguments a line each in `calls`
  local function curl(instant, range)
    h.write(dir .. '/instant.json', { instant })
    h.write(dir .. '/range.json', { range })
    h.write(dir .. '/bin/curl', {
      '#!/bin/sh',
      'for arg; do url=$arg; done',
      'echo "$url" >> "' .. dir .. '/calls"',
      'case "$url" in',
      '  *query_range*) cat "' .. dir .. '/range.json" ;;',
      '  *) cat "' .. dir .. '/instant.json" ;;',
      'esac',
    })
    vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
  end

  it('asks the server for now and for the last hour', function()
    curl(
      vim.json.encode({
        status = 'success',
        data = {
          resultType = 'vector',
          result = { { metric = { job = 'a' }, value = { 1, '3' } } },
        },
      }),
      vim.json.encode({
        status = 'success',
        data = {
          resultType = 'matrix',
          result = {
            { metric = { job = 'a' }, values = { { 1, '1' }, { 2, '3' } } },
          },
        },
      })
    )
    local done = false
    promql.run('sum(rate(x[5m])) > 0', dir, function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    local calls = vim.fn.readfile(dir .. '/calls')
    assert.equals(
      'https://prom.example/api/v1/query?query=sum%28rate%28x%5B5m%5D%29%29%20%3E%200',
      calls[1]
    )
    assert.is_truthy(calls[2]:find('/api/v1/query_range?query=sum%28', 1, true))
    assert.is_truthy(calls[2]:find('&step=60', 1, true))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert.is_truthy(text:find('- `{job="a"}` **3** ▁█', 1, true))
  end)

  it('says what Prometheus said of a bad expression', function()
    curl(
      vim.json.encode({
        status = 'error',
        errorType = 'bad_data',
        error = 'parse error at char 5',
      }),
      '{}'
    )
    local done = false
    promql.run('sum(', dir, function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.equals('Prometheus: parse error at char 5', notes[#notes])
  end)

  it('reads the error of a 400, as curl prints its body', function()
    h.write(dir .. '/bin/curl', {
      '#!/bin/sh',
      [[echo '{"status":"error","errorType":"bad_data","error":"1:5: parse error"}']],
      'echo "curl: (22) The requested URL returned error: 400" >&2',
      'exit 22',
    })
    vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
    local done = false
    promql.run('sum(', dir, function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.equals('Prometheus: 1:5: parse error', notes[#notes])
  end)

  it('says why when the server is no Prometheus', function()
    h.write(dir .. '/bin/curl', {
      '#!/bin/sh',
      'echo "<html>login</html>"',
    })
    vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
    local done = false
    promql.run('up', dir, function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.equals(
      'Prometheus: the server answered with something not the Prometheus API',
      notes[#notes]
    )
  end)

  it('says where to name the server when none is', function()
    restore_globals()
    restore_globals = h.stub(_G, 'DyNeo', {})
    curl('{}', '{}')
    local done = false
    promql.run('up', dir, function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.is_truthy(
      notes[#notes]:find('git config dyneo.prometheusUrl', 1, true)
    )
    assert.equals(0, vim.fn.filereadable(dir .. '/calls'))
  end)

  it('takes the lines of a range as the expression', function()
    curl(
      vim.json.encode({
        status = 'success',
        data = { resultType = 'scalar', result = { 1, '2' } },
      }),
      '{}'
    )
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/q.txt'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'ignored', '1 +', '1' })
    local done = false
    promql.under_cursor({ line1 = 2, line2 = 3 }, function() done = true end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.is_truthy(
      vim.fn.readfile(dir .. '/calls')[1]:find('query=1%20%2B%0A1', 1, true)
    )
  end)

  describe('promtool', function()
    local function promtool(lines)
      h.write(
        dir .. '/bin/promtool',
        vim.list_extend({
          '#!/bin/sh',
          'echo "$PWD $*" >> "' .. dir .. '/calls"',
        }, lines)
      )
      vim.fn.setfperm(dir .. '/bin/promtool', 'rwxr-xr-x')
    end

    it('checks a rule file, beside it', function()
      promtool({ 'echo "SUCCESS: 2 rules found"' })
      h.write(dir .. '/rules/api.yml', RULES)
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/rules/api.yml'))
      local done = false
      promql.test(function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      assert.same(
        { dir .. '/rules check rules ./api.yml' },
        vim.fn.readfile(dir .. '/calls')
      )
      assert.is_truthy(notes[#notes]:find('SUCCESS: 2 rules found', 1, true))
    end)

    it('runs a rule test, and shows why it failed', function()
      promtool({
        'echo "FAILED:" >&2',
        'echo "  alertname: HighErrors" >&2',
        'exit 1',
      })
      h.write(dir .. '/rules/api_test.yml', { 'rule_files:', '  - api.yml' })
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/rules/api_test.yml'))
      local done = false
      promql.test(function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      assert.same(
        { dir .. '/rules test rules ./api_test.yml' },
        vim.fn.readfile(dir .. '/calls')
      )
      assert.equals('Rule tests failed', notes[#notes])
      assert.same(
        { 'FAILED:', '  alertname: HighErrors' },
        vim.api.nvim_buf_get_lines(0, 0, -1, false)
      )
    end)

    it(
      'asks for an unsaved file to be written, and a rule file at all',
      function()
        promtool({})
        h.write(dir .. '/x.yml', { 'a: 1' })
        vim.cmd.edit(vim.fn.fnameescape(dir .. '/x.yml'))
        promql.test()
        vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'groups:' })
        promql.test()
        assert.same({
          'Neither a rule file (groups:) nor a rule test (rule_files:)',
          'Write the file first: promtool reads it from disk',
        }, notes)
      end
    )
  end)
end)
