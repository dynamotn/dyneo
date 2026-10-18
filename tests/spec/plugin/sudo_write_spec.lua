local h = require('helpers')

describe('plugin/sudo_write', function()
  before_each(function() dofile(h.root .. '/plugin/sudo_write.lua') end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  it('writes through sudo into the file, leaving it unmodified', function()
    local dir, cleanup = h.tmpdir()
    local target = dir .. '/root-owned.conf'
    vim.fn.writefile({ 'old' }, target)
    local restore_job = h.stub(vim.fn, 'jobstart', function(cmd, opts)
      assert.are.equal('sudo', cmd[1])
      -- Stands in for `sudo cp`
      vim.fn.writefile(vim.fn.readfile(cmd[3]), cmd[4])
      opts.on_exit(0, 0)
      return 1
    end)
    vim.cmd.edit(target)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new' })
    local bufnr = vim.api.nvim_get_current_buf()
    vim.cmd('DySudoWrite')
    vim.cmd.stopinsert()
    vim.wait(500, function() return not vim.bo[bufnr].modified end)
    restore_job()
    assert.are.same({ 'new' }, vim.fn.readfile(target))
    assert.is_false(vim.bo[bufnr].modified)
    cleanup()
  end)

  it('says when the copy failed, leaving the buffer modified', function()
    local dir, cleanup = h.tmpdir()
    local target = dir .. '/root-owned.conf'
    vim.fn.writefile({ 'old' }, target)
    local messages = {}
    local restores = {
      h.stub(vim.fn, 'jobstart', function(_, opts)
        opts.on_exit(0, 1)
        return 1
      end),
      h.stub(vim, 'notify', function(msg) table.insert(messages, msg) end),
    }
    vim.cmd.edit(target)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'new' })
    local bufnr = vim.api.nvim_get_current_buf()
    vim.cmd('DySudoWrite')
    vim.cmd.stopinsert()
    vim.wait(500, function() return #messages > 0 end)
    for _, restore in ipairs(restores) do
      restore()
    end
    assert.same({ 'DySudoWrite failed' }, messages)
    assert.is_true(vim.bo[bufnr].modified)
    assert.same({ 'old' }, vim.fn.readfile(target))
    cleanup()
  end)

  it('refuses a buffer with no file', function()
    local messages = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(messages, msg) end
    )
    vim.api.nvim_set_current_buf(h.buffer())
    vim.cmd('DySudoWrite')
    restore()
    assert.are.same({ 'DySudoWrite: the buffer has no file' }, messages)
  end)
end)
