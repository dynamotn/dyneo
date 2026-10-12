local h = require('helpers')

local SCRIPT = {
  'import os', -- 1: above the first marker
  '', -- 2
  '# %% Load', -- 3
  'x = 1', -- 4
  '', -- 5
  '#%%', -- 6
  'y = 2', -- 7
  '    # %% indented: no marker', -- 8
  '# %% [markdown]', -- 9
  '# notes', -- 10
}

describe('util.cells', function()
  local cells, bufnr

  before_each(function()
    h.unload('util.cells')
    cells = require('util.cells')
    bufnr = h.buffer({ lines = SCRIPT, filetype = 'python' })
    vim.api.nvim_set_current_buf(bufnr)
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  it('finds the cell holding a line, by the markers iron.nvim sends', function()
    assert.same({ 1, 2 }, { cells.range(bufnr, 1) })
    assert.same({ 3, 5 }, { cells.range(bufnr, 3) })
    assert.same({ 3, 5 }, { cells.range(bufnr, 5) })
    assert.same({ 6, 8 }, { cells.range(bufnr, 8) })
    assert.same({ 9, 10 }, { cells.range(bufnr, 10) })
  end)

  it('selects a cell with its marker, or its code alone', function()
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    assert.same({
      from = { line = 3, col = 1 },
      to = { line = 5, col = 1 },
      vis_mode = 'V',
    }, cells.textobject('a'))
    -- Without the marker, and without the blank line closing it
    assert.same({
      from = { line = 4, col = 1 },
      to = { line = 4, col = 5 },
      vis_mode = 'V',
    }, cells.textobject('i'))
  end)

  it('has no inner cell for a marker with nothing under it', function()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '# %%', '', '# %%' })
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    assert.is_nil(cells.textobject('i'))
  end)

  it('moves between markers, with a count, and stops at the last', function()
    dofile(h.root .. '/ftplugin/python.lua')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('normal ]j')
    assert.equal(3, vim.fn.line('.'))
    vim.cmd('normal 2]j')
    assert.equal(9, vim.fn.line('.'))
    vim.cmd('normal ]j')
    assert.equal(9, vim.fn.line('.'))
    vim.cmd('normal [j')
    assert.equal(6, vim.fn.line('.'))
  end)

  it('maps the moves and the text object in a Python buffer', function()
    dofile(h.root .. '/ftplugin/python.lua')
    assert.equal('Next Cell', vim.fn.maparg(']j', 'n', false, true).desc)
    assert.equal('Previous Cell', vim.fn.maparg('[j', 'o', false, true).desc)
    assert.is_function(vim.b.miniai_config.custom_textobjects.j)
  end)
end)
