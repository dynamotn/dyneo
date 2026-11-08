local h = require('helpers')

describe('tools.local_history', function()
  local history, dir, cleanup, restores, sensitive

  before_each(function()
    h.unload('tools.local_history')
    history = require('tools.local_history')
    dir, cleanup = h.tmpdir()
    sensitive = false
    restores = {
      h.stub(history, 'dir', function() return dir .. '/history' end),
      h.stub(
        require('util.sensitive'),
        'is_sensitive',
        function() return sensitive end
      ),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- A buffer on `path` holding `lines`, written to disk
  local function written(path, lines)
    h.write(path, lines)
    local bufnr = vim.fn.bufadd(path)
    vim.fn.bufload(bufnr)
    return bufnr
  end

  it('copies a file after it is written, once the write is done', function()
    dofile(h.root .. '/plugin/local_history.lua')
    assert.equals(2, vim.fn.exists(':DyLocalHistory'))
    local bufnr = written(dir .. '/w.txt', { 'one' })
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    -- Deferred: the write itself is not held up
    assert.same({}, history.list(dir .. '/w.txt'))
    assert.is_true(
      vim.wait(1000, function() return #history.list(dir .. '/w.txt') == 1 end)
    )
  end)

  it('keeps a private copy of a file as it is written', function()
    local bufnr = written(dir .. '/a.txt', { 'one' })
    history.save(bufnr)
    local snapshots = history.list(dir .. '/a.txt')
    assert.equals(1, #snapshots)
    assert.same({ 'one' }, vim.fn.readfile(snapshots[1].file))
    assert.equals('rw-------', vim.fn.getfperm(snapshots[1].file))
  end)

  it('keeps nothing new when the file did not change', function()
    local bufnr = written(dir .. '/a.txt', { 'one' })
    history.save(bufnr)
    history.save(bufnr)
    assert.equals(1, #history.list(dir .. '/a.txt'))
    h.write(dir .. '/a.txt', { 'two' })
    history.save(bufnr)
    local snapshots = history.list(dir .. '/a.txt')
    assert.equals(2, #snapshots)
    -- Newest first
    assert.same({ 'two' }, vim.fn.readfile(snapshots[1].file))
  end)

  it('keeps only the newest copies', function()
    table.insert(restores, h.stub(history, 'LIMIT', 3))
    local bufnr = written(dir .. '/a.txt', { '0' })
    for i = 1, 5 do
      h.write(dir .. '/a.txt', { tostring(i) })
      history.save(bufnr)
    end
    local snapshots = history.list(dir .. '/a.txt')
    assert.equals(3, #snapshots)
    assert.same({ '5' }, vim.fn.readfile(snapshots[1].file))
    assert.same({ '3' }, vim.fn.readfile(snapshots[3].file))
  end)

  it('copies no secret, no large file and no scratch buffer', function()
    sensitive = true
    history.save(written(dir .. '/.env', { 'TOKEN=x' }))
    assert.same({}, history.list(dir .. '/.env'))
    sensitive = false

    table.insert(restores, h.stub(history, 'MAX_BYTES', 4))
    history.save(written(dir .. '/big.txt', { 'too long' }))
    assert.same({}, history.list(dir .. '/big.txt'))

    local scratch = vim.api.nvim_create_buf(false, true)
    history.save(scratch)
    assert.same({}, vim.fn.glob(dir .. '/history/*', true, true))
  end)

  it('shows a copy against the buffer, side by side', function()
    local bufnr = written(dir .. '/a.txt', { 'old' })
    history.save(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'new' })
    table.insert(
      restores,
      h.stub(
        vim.ui,
        'select',
        function(items, _, on_choice) on_choice(items[1]) end
      )
    )
    history.open()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    assert.equals(2, #wins)
    for _, win in ipairs(wins) do
      assert.is_true(vim.wo[win].diff)
    end
    local copy = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())
    assert.same({ 'old' }, vim.api.nvim_buf_get_lines(copy, 0, -1, false))
    assert.is_false(vim.bo[copy].modifiable)
  end)
end)
