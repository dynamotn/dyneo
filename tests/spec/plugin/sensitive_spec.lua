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

  describe('a file in the temporary directory', function()
    local tmpdir, swapfile, real, link
    before_each(function()
      tmpdir, swapfile = vim.env.TMPDIR, vim.o.swapfile
      vim.o.swapfile = true
      -- `real` stands for `/private/tmp`, and `link` for `/tmp` pointing at it
      real, link = dir .. '/private-tmp', dir .. '/tmp'
      vim.fn.mkdir(real, 'p')
      assert(vim.uv.fs_symlink(real, link))
    end)
    after_each(function()
      vim.env.TMPDIR, vim.o.swapfile = tmpdir, swapfile
      vim.cmd('silent! %bwipeout!')
    end)

    ---@param tmp string `$TMPDIR`
    ---@param file string
    ---@return boolean
    local function keeps_swap(tmp, file)
      vim.env.TMPDIR = tmp
      vim.cmd.edit(vim.fn.fnameescape(file))
      return vim.bo.swapfile
    end

    it(
      'counts by its real path when $TMPDIR is a link',
      function() assert.is_false(keeps_swap(link, real .. '/secret.txt')) end
    )

    it(
      'counts by a link into $TMPDIR',
      function() assert.is_false(keeps_swap(real, link .. '/new/secret.txt')) end
    )
  end)

  it('counts a file by its name outside the temporary directory', function()
    -- `$TMPDIR` moved away, the scratch directory is an ordinary one
    local tmpdir, swapfile = vim.env.TMPDIR, vim.o.swapfile
    vim.env.TMPDIR, vim.o.swapfile = dir .. '/elsewhere', true
    vim.cmd.edit(dir .. '/prod.env')
    assert.is_false(vim.bo.undofile)
    assert.is_false(vim.bo.swapfile)
    vim.cmd('bwipeout!')
    vim.cmd.edit(dir .. '/notes.txt')
    assert.is_true(vim.bo.swapfile)
    vim.cmd('bwipeout!')
    vim.env.TMPDIR, vim.o.swapfile = tmpdir, swapfile
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
