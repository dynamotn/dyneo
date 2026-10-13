local h = require('helpers')

describe('plugin/sensitive', function()
  local dir, cleanup, backup, writebackup
  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    backup, writebackup = vim.o.backup, vim.o.writebackup
    vim.o.backup, vim.o.writebackup = true, true
    dofile(h.root .. '/plugin/sensitive.lua')
  end)
  after_each(function()
    vim.o.backup, vim.o.writebackup = backup, writebackup
    cleanup()
  end)

  it('restores backup options after a write that failed', function()
    -- The temporary directory counts as leaving a copy behind
    local file = dir .. '/missing/secret.txt'
    vim.cmd.edit(file)
    assert.is_false(pcall(vim.cmd.write))
    vim.wait(100, function() return vim.o.writebackup end)
    assert.is_true(vim.o.backup)
    assert.is_true(vim.o.writebackup)
    vim.cmd('bwipeout!')
  end)
end)
