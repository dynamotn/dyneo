local h = require('helpers')

describe('tools.matrix', function()
  local matrix

  before_each(function()
    h.unload('tools.matrix')
    matrix = require('tools.matrix')
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  it('is mapped in a Markdown buffer', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { '# Notes' } }))
    dofile(h.root .. '/ftplugin/markdown.lua')
    local map = vim.fn.maparg('<localleader>m', 'n', false, true)
    assert.equals(1, map.buffer)
    assert.equals('<cmd>DyMatrix<cr>', map.rhs)
  end)

  it('finds the table around a line', function()
    local lines = { 'text', '| a |', '| - |', '| b |', '', '| c |' }
    assert.same({ 2, 4 }, { matrix.bounds(lines, 3) })
    assert.is_nil(matrix.bounds(lines, 1))
  end)

  it('sums weight times score, and ignores the old total', function()
    local m = assert(matrix.parse({
      '| Criterion | Weight | A | B |',
      '| --- | --: | --: | --: |',
      '| Cost | 3 | 3 | 4 |',
      '| Speed | 2 | 4 | |',
      '| **Total** | | 99 | 99 |',
    }))
    assert.same({ 17, 12 }, m.totals)
    assert.equals(2, #m.rows)
    local _, err = matrix.parse({ '| a | b | c |', '| - | - | - |' })
    assert.is_truthy(err:find('Weight', 1, true))
  end)

  it('reads emphasis as the number, and names what is none', function()
    local m = assert(matrix.parse({
      '| Criterion | Weight | A | B |',
      '| --- | --: | --: | --: |',
      '| Cost | **3** | high | 4/5 |',
      '| Speed | 2 | _4_ | |',
    }, 10))
    assert.same({ 8, 0 }, m.totals)
    assert.same({ '12: `high`', '12: `4/5`' }, m.ignored)
  end)

  it('refuses a row wider than the header, naming its line', function()
    local m, err = matrix.parse({
      '| Criterion | Weight | A |',
      '| --- | --: | --: |',
      '| Cost | 3 | 3 | 4 |',
      '| Speed | 2 | 1 |',
      '| **Total** | | 9 | 9 |',
    }, 4)
    assert.is_nil(m)
    assert.equals('More cells than the header has columns, line 6, 8', err)
  end)

  it('writes a big total without an exponent', function()
    local m = assert(matrix.parse({
      '| Criterion | Weight | A |',
      '| --- | --: | --: |',
      '| Cost | 1234567 | 1 |',
    }))
    assert.equals('| **1234567** |', matrix.render(m)[4]:match('|[^|]*|$'))
  end)

  it(
    'lines its columns up, the best total in bold',
    function()
      assert.same(
        {
          '| Criterion | Weight | A   | B      |',
          '| --------- | -----: | --: | -----: |',
          '| Cost      |      3 | 2.5 |      4 |',
          '| **Total** |        | 7.5 | **12** |',
        },
        matrix.render({
          header = { 'Criterion', 'Weight', 'A', 'B' },
          rows = { { 'Cost', '3', '2.5', '4' } },
          totals = { 7.5, 12 },
        })
      )
    end
  )

  it('works out the table under the cursor', function()
    vim.api.nvim_set_current_buf(h.buffer({
      lines = {
        '| Criterion | Weight | A | B |',
        '| --- | --: | --: | --: |',
        '| Cost | 3 | 3 | 4 |',
        '| **Total** | | | |',
      },
    }))
    vim.api.nvim_win_set_cursor(0, { 3, 0 })
    matrix.update()
    assert.equals(
      '| **Total** |        |   9 | **12** |',
      vim.api.nvim_buf_get_lines(0, 3, 4, false)[1]
    )
  end)

  it('leaves a table it refuses as it is, and warns of what is none', function()
    local lines = {
      '| Criterion | Weight | A |',
      '| --- | --: | --: |',
      '| Cost | 3 | 3 | 4 |',
    }
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    vim.api.nvim_set_current_buf(h.buffer({ lines = lines }))
    matrix.update()
    assert.same(lines, vim.api.nvim_buf_get_lines(0, 0, -1, false))
    vim.api.nvim_buf_set_lines(0, 2, 3, false, { '| Cost | 3 | high |' })
    matrix.update()
    restore()
    assert.same({
      'More cells than the header has columns, line 3',
      'Not numbers, counted as nought, at line\n3: `high`',
    }, notes)
  end)

  it('writes a new one as the options of a decision record', function()
    vim.api.nvim_set_current_buf(h.buffer({
      lines = {
        '# 2. Pick a queue',
        '',
        '## Context',
        '',
        '## Decision',
        '',
      },
    }))
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    matrix.update()
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.equals('## Options', lines[5])
    assert.is_truthy(lines[7]:find('^| Criterion'))
    assert.is_truthy(lines[12]:find('^| %*%*Total%*%*'))
    assert.equals('', lines[13])
    assert.equals('## Decision', lines[14])
  end)
end)
