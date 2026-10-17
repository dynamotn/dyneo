local h = require('helpers')

describe('tools.query', function()
  local query, dir, cleanup, path, notes, restore_notify

  --- A fake `name` that prints its arguments, then stdin, or fails on `bad`
  local function fake(name)
    h.write(dir .. '/bin/' .. name, {
      '#!/bin/sh',
      'case "$*" in',
      '  *bad*) echo "syntax error" >&2; exit 3 ;;',
      '  *slow*) sleep 5 ;;',
      'esac',
      'echo "args: $*"',
      'cat',
    })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  before_each(function()
    h.unload('tools.query')
    query = require('tools.query')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    fake('jq')
    fake('yq')
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    for _, q in pairs(query.open_queries) do
      query.close(q)
    end
    vim.cmd('stopinsert')
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    vim.env.PATH = path
    restore_notify()
    cleanup()
  end)

  --- The lines of the result once a run has put them there
  local function result_of(q, want)
    assert.is_true(
      vim.wait(5000, function()
        local lines = vim.api.nvim_buf_get_lines(q.result, 0, -1, false)
        return lines[1] ~= nil and lines[1]:find(want, 1, true) ~= nil
      end, 20),
      'never got ' .. want
    )
    return vim.api.nvim_buf_get_lines(q.result, 0, -1, false)
  end

  local function json_buffer(lines)
    local bufnr = h.buffer({ lines = lines })
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'json'
    return bufnr
  end

  it('picks jq for JSON and yq for YAML', function()
    assert.equals('jq', query.tool('json'))
    assert.equals('jq', query.tool('jsonc'))
    assert.equals('yq', query.tool('yaml.helm-values'))
    assert.is_nil(query.tool('lua'))
    assert.same({ 'yq', 'eval', '.a', '-' }, query.argv('yq', '.a'))
    assert.same({ 'jq', '.a' }, query.argv('jq', '.a'))
  end)

  it('cuts what it keeps of a run', function()
    query.MAX_OUTPUT = 4
    local lines, cut = query.output('ab\ncdef\n')
    assert.same({ 'ab', 'c' }, lines)
    assert.is_true(cut)
  end)

  it('runs the expression against the buffer, and again on a change', function()
    local source = json_buffer({ '{"a": 1}' })
    local q = assert(query.open('.a'))
    assert.same({ 'args: .a', '{"a": 1}' }, result_of(q, 'args: .a'))
    vim.api.nvim_buf_set_lines(q.expr, 0, -1, false, { '.b' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = q.expr })
    assert.same({ 'args: .b', '{"a": 1}' }, result_of(q, 'args: .b'))
    vim.api.nvim_buf_set_lines(source, 0, -1, false, { '{"b": 2}' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = source })
    assert.is_true(
      vim.wait(
        5000,
        function()
          return vim.api.nvim_buf_get_lines(q.result, 1, 2, false)[1]
            == '{"b": 2}'
        end,
        20
      )
    )
  end)

  it('shows what the tool says of a bad expression', function()
    json_buffer({ '{}' })
    local q = assert(query.open('bad'))
    assert.same({ 'syntax error' }, result_of(q, 'syntax error'))
    local win = vim.fn.win_findbuf(q.result)[1]
    assert.equals(' jq: error', vim.wo[win].winbar)
  end)

  it('keeps only the last of two runs', function()
    json_buffer({ '{}' })
    local q = assert(query.open('slow'))
    vim.api.nvim_buf_set_lines(q.expr, 0, -1, false, { '.fast' })
    query.run(q)
    result_of(q, 'args: .fast')
    vim.wait(200)
    assert.equals(
      'args: .fast',
      vim.api.nvim_buf_get_lines(q.result, 0, 1, false)[1]
    )
  end)

  it('holds the result of a sensitive buffer back from AI', function()
    local source = json_buffer({ '{}' })
    require('util.sensitive').mark(source, 'a spec')
    local q = assert(query.open())
    assert.is_true(require('util.sensitive').is_sensitive(q.result))
  end)

  it('holds back every result, which can read the environment', function()
    json_buffer({ '{}' })
    local q = assert(query.open('$ENV'))
    assert.is_true(require('util.sensitive').is_sensitive(q.result))
  end)

  it('closes both windows and stops listening', function()
    json_buffer({ '{}' })
    local q = assert(query.open())
    local group = q.group
    query.close(q)
    assert.is_false(vim.api.nvim_buf_is_valid(q.expr))
    assert.is_false(vim.api.nvim_buf_is_valid(q.result))
    assert.is_nil(query.open_queries[q.expr])
    assert.is_false(pcall(vim.api.nvim_get_autocmds, { group = group }))
  end)

  it('turns down a buffer that is neither JSON nor YAML', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'x' } }))
    assert.is_nil(query.open())
    assert.equals(
      'Not a JSON or YAML buffer: jq and yq read nothing else',
      notes[1]
    )
  end)
end)
