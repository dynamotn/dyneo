local h = require('helpers')

describe('config.autocmds', function()
  before_each(function()
    h.globals()
    dofile(h.root .. '/lua/config/autocmds.lua')
  end)

  it('creates its autocommand groups', function()
    for _, group in ipairs({
      'dyneo_terminal',
      'dyneo_cursor_active_window',
      'dyneo_cursor_inactive_window',
      'dyneo_auto_relative_number',
    }) do
      assert.is_true(#vim.api.nvim_get_autocmds({ group = group }) > 0, group)
    end
  end)

  it('checks for a changed file on focus, not in a scratch buffer', function()
    local ran = {}
    local restore = h.stub(vim, 'cmd', function(cmd) table.insert(ran, cmd) end)
    vim.api.nvim_set_current_buf(h.buffer())
    vim.api.nvim_exec_autocmds('FocusGained', {})
    vim.bo.buftype = 'nofile'
    vim.api.nvim_exec_autocmds('FocusGained', {})
    restore()
    assert.same({ 'checktime' }, ran)
    vim.cmd('silent! %bwipeout!')
  end)

  it('highlights a yank, through the API of the Neovim running', function()
    local calls = {}
    local restores = {
      h.stub(vim.hl, 'on_yank', function() table.insert(calls, 'on_yank') end),
      h.stub(vim.hl, 'hl_op', function() table.insert(calls, 'hl_op') end),
    }
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'text' } }))
    vim.api.nvim_exec_autocmds('TextYankPost', {})
    table.insert(restores, h.stub(vim.fn, 'has', function() return 1 end))
    vim.api.nvim_exec_autocmds('TextYankPost', {})
    restores[3]()
    table.insert(restores, h.stub(vim.fn, 'has', function() return 0 end))
    vim.api.nvim_exec_autocmds('TextYankPost', {})
    for i = #restores, 1, -1 do
      restores[i]()
    end
    assert.equals('hl_op', calls[2])
    assert.equals('on_yank', calls[3])
    vim.cmd('silent! %bwipeout!')
  end)

  it('evens the splits of every tab when the terminal is resized', function()
    vim.cmd.tabnew()
    vim.cmd.vsplit()
    vim.cmd.tabnext(1)
    vim.api.nvim_exec_autocmds('VimResized', {})
    assert.equals(1, vim.fn.tabpagenr())
    local widths = {}
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(2)) do
      table.insert(widths, vim.api.nvim_win_get_width(win))
    end
    assert.is_true(math.abs(widths[1] - widths[2]) <= 1)
    vim.cmd('tabclose 2')
  end)

  describe('last location', function()
    local dir, cleanup
    before_each(function()
      dir, cleanup = h.tmpdir()
    end)
    after_each(function()
      vim.cmd('silent! %bwipeout!')
      cleanup()
    end)

    it('goes back to the last position of the file once', function()
      h.write(dir .. '/a.txt', { 'one', 'two', 'three' })
      vim.cmd.edit(dir .. '/a.txt')
      -- The read itself already asked once
      assert.is_true(vim.b.dyneo_last_loc)
      vim.b.dyneo_last_loc = nil
      vim.api.nvim_buf_set_mark(0, '"', 3, 0, {})
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds('BufReadPost', { buffer = 0 })
      assert.equals(3, vim.fn.line('.'))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds('BufReadPost', { buffer = 0 })
      assert.equals(1, vim.fn.line('.'))
    end)

    it('leaves a commit message at its top', function()
      h.write(dir .. '/COMMIT_EDITMSG', { 'subject', '', 'body' })
      vim.cmd.edit(dir .. '/COMMIT_EDITMSG')
      vim.bo.filetype = 'gitcommit'
      vim.api.nvim_buf_set_mark(0, '"', 3, 0, {})
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      vim.api.nvim_exec_autocmds('BufReadPost', { buffer = 0 })
      assert.equals(1, vim.fn.line('.'))
      assert.is_nil(vim.b.dyneo_last_loc)
    end)
  end)

  it('gives a terminal without a filetype one', function()
    vim.cmd.terminal('true')
    local bufnr = vim.api.nvim_get_current_buf()
    assert.equals('terminal', vim.bo[bufnr].filetype)
    vim.api.nvim_buf_delete(bufnr, { force = true })
  end)

  it('hides the cursorline while inserting and brings it back', function()
    vim.wo.cursorline = true
    vim.api.nvim_exec_autocmds('InsertEnter', {})
    assert.is_false(vim.wo.cursorline)
    vim.api.nvim_exec_autocmds('InsertLeave', {})
    assert.is_true(vim.wo.cursorline)
  end)

  it('leaves the cursorline off when it was off', function()
    vim.wo.cursorline = false
    vim.api.nvim_exec_autocmds('InsertEnter', {})
    vim.api.nvim_exec_autocmds('InsertLeave', {})
    assert.is_false(vim.wo.cursorline)
  end)

  it('drops relative numbers on the command line only', function()
    vim.wo.relativenumber = true
    vim.api.nvim_exec_autocmds('CmdlineEnter', { pattern = '/' })
    assert.is_true(vim.wo.relativenumber)
    vim.api.nvim_exec_autocmds('CmdlineEnter', { pattern = ':' })
    assert.is_false(vim.wo.relativenumber)
    vim.api.nvim_exec_autocmds('CmdlineLeave', {})
    assert.is_true(vim.wo.relativenumber)
  end)

  it(
    'watches the clock only when day_night is enabled',
    function()
      assert.are.same({}, vim.api.nvim_get_autocmds({ event = 'VimResume' }))
    end
  )

  describe('sensitive files', function()
    local dir, cleanup
    before_each(function()
      dir, cleanup = h.tmpdir()
      dofile(h.root .. '/plugin/sensitive.lua')
    end)
    after_each(function() cleanup() end)

    it('keeps no undo or swap file of a sensitive file', function()
      local path = dir .. '/.env'
      vim.fn.writefile({ 'TOKEN=x' }, path)
      vim.cmd.edit(path)
      assert.is_false(vim.bo.undofile)
      assert.is_false(vim.bo.swapfile)
      vim.cmd('bwipeout!')
    end)

    it('turns backups off for the write only', function()
      local saved = vim.o.backup
      vim.o.backup = true
      local path = dir .. '/.env'
      vim.cmd.edit(path)
      local during
      vim.api.nvim_create_autocmd('BufWritePre', {
        once = true,
        callback = function() during = vim.o.backup end,
      })
      vim.cmd.write()
      assert.is_false(during)
      assert.is_true(vim.o.backup)
      vim.cmd('bwipeout!')
      vim.o.backup = saved
    end)
  end)

  describe('close with q', function()
    it('leaves `q` alone in a help file open for editing', function()
      local bufnr = h.buffer({ lines = { 'text' } })
      vim.api.nvim_set_current_buf(bufnr)
      vim.bo[bufnr].filetype = 'help'
      vim.wait(50)
      assert.same({}, vim.fn.maparg('q', 'n', false, true))
    end)

    it('closes the window and drops the buffer on `q`', function()
      vim.cmd.split()
      local bufnr = h.buffer({ lines = { 'text' } })
      vim.api.nvim_set_current_buf(bufnr)
      vim.bo[bufnr].filetype = 'qf'
      vim.wait(50)
      assert.is_false(vim.bo[bufnr].buflisted)
      vim.bo[bufnr].modified = false
      local windows = #vim.api.nvim_list_wins()
      vim.fn.maparg('q', 'n', false, true).callback()
      assert.equals(windows - 1, #vim.api.nvim_list_wins())
      assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
    end)

    it('keeps a buffer with unsaved changes on `q`', function()
      vim.cmd.split()
      local bufnr = h.buffer({ lines = { 'text' } })
      vim.api.nvim_set_current_buf(bufnr)
      vim.bo[bufnr].filetype = 'qf'
      vim.wait(50)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'changed' })
      vim.fn.maparg('q', 'n', false, true).callback()
      assert.is_true(vim.api.nvim_buf_is_valid(bufnr))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it('copes with a buffer wiped before `q` is mapped', function()
      local bufnr = h.buffer({ lines = { 'text' } })
      vim.bo[bufnr].filetype = 'qf'
      vim.api.nvim_buf_delete(bufnr, { force = true })
      vim.v.errmsg = ''
      vim.wait(50)
      assert.are.equal('', vim.v.errmsg)
    end)
  end)
end)
