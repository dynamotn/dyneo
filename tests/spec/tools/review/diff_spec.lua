local h = require('helpers')

describe('tools.review.diff', function()
  local diff, dir, cleanup, notes, restore

  before_each(function()
    h.unload('tools.review.diff')
    diff = require('tools.review.diff')
    dir, cleanup = h.tmpdir()
    notes = {}
    restore = h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
  end)

  after_each(function()
    restore()
    cleanup()
  end)

  --- Whether a buffer named `name` exists
  local function has_buffer(name)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr) == name then return true end
    end
    return false
  end

  describe('open', function()
    local session

    before_each(function()
      vim.fn.mkdir(dir .. '/wt/real', 'p')
      h.write(dir .. '/outside.txt', { 'not of the pull request' })
      session = {
        worktree = dir .. '/wt',
        merge_base = ('a'):rep(40),
        pull = { head_sha = ('c'):rep(40) },
      }
    end)

    it('never loads a file of the worktree that is a symlink', function()
      vim.uv.fs_symlink(dir .. '/outside.txt', dir .. '/wt/link.txt')
      assert.is_false(diff.open(session, 'link.txt'))
      assert.is_false(has_buffer(dir .. '/wt/link.txt'))
      assert.matches('link.txt is a symlink to ', notes[#notes], 1, true)
      assert.matches(dir .. '/outside.txt', notes[#notes], 1, true)
    end)

    it('never loads a file under a directory that is a symlink', function()
      vim.uv.fs_symlink(dir, dir .. '/wt/up')
      assert.is_false(diff.open(session, 'up/outside.txt'))
      assert.is_false(has_buffer(dir .. '/wt/up/outside.txt'))
      assert.matches('up is a symlink to ', notes[#notes], 1, true)
    end)
  end)
end)
