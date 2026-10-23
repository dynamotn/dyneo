local h = require('helpers')

describe('tools.review.diff', function()
  local diff, dir, cleanup, notes, restore

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  before_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_review_diff')
    h.unload('tools.review.diff')
    diff = require('tools.review.diff')
    dir, cleanup = h.tmpdir()
    notes, restore = {}, {}
    stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_review_diff')
    pcall(vim.api.nvim_del_user_command, 'CodeDiff')
    vim.cmd('silent! tabonly!')
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.startswith(vim.api.nvim_buf_get_name(bufnr), dir) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
      end
    end
    cleanup()
  end)

  --- Whether a buffer named `name` exists
  local function has_buffer(name)
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_get_name(bufnr) == name then return true end
    end
    return false
  end

  --- Whether `msg` was said
  local function said(msg) return vim.tbl_contains(notes, msg) end

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

    it('says codediff.nvim is needed when it is not installed', function()
      pcall(vim.api.nvim_del_user_command, 'CodeDiff')
      h.write(dir .. '/wt/real/a.lua', { 'x' })
      assert.is_false(diff.open(session, 'real/a.lua'))
      assert.is_true(
        said('codediff.nvim is not installed: `:DyReview` needs it')
      )
    end)
  end)

  describe('with codediff', function()
    local session, runs, fail, lifecycle, buffers, windows, seen

    --- Open the diff of `path` the way codediff does: a new tab, then
    --- `CodeDiffOpen` naming it
    ---@return integer tab
    local function codediff_opens()
      vim.cmd('tabnew')
      local tab = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      return tab
    end

    --- A buffer as codediff names the side it reads from git
    local function virtual(path)
      return h.buffer({ name = 'codediff://' .. dir .. '/git/' .. path })
    end

    before_each(function()
      session = {
        worktree = dir .. '/wt',
        merge_base = ('a'):rep(40),
        pull = { head_sha = ('c'):rep(40) },
      }
      h.write(dir .. '/wt/a.lua', { 'new' })
      runs, fail, buffers, windows, seen = {}, {}, {}, {}, {}
      vim.api.nvim_create_user_command('CodeDiff', function(args)
        runs[#runs + 1] = args.fargs
        if fail[#runs] then error(fail[#runs]) end
      end, { nargs = '*' })
      lifecycle = {
        get_buffers = function(tab)
          local b = buffers[tab]
          if type(b) == 'string' then error(b) end
          if b then return b[1], b[2] end
        end,
        get_windows = function(tab)
          local w = windows[tab]
          if type(w) == 'string' then error(w) end
          if w then return w[1], w[2] end
        end,
      }
      stub(package.loaded, 'codediff.ui.lifecycle', lifecycle)
      diff.on_buffer(
        function(bufnr, path, side) seen[#seen + 1] = { bufnr, path, side } end
      )
    end)

    it('opens a changed file against the merge base', function()
      assert.equal('opened', diff.open(session, 'a.lua'))
      assert.same({ { 'file', session.merge_base } }, runs)
      local bufnr = vim.fn.bufnr(dir .. '/wt/a.lua')
      assert.is_true(vim.bo[bufnr].buflisted)
      assert.same({ 'new' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))

      local old = virtual('a.lua')
      vim.cmd('tabnew')
      local tab = vim.api.nvim_get_current_tabpage()
      buffers[tab] = { old, bufnr }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      assert.same({ { old, 'a.lua', 'old' }, { bufnr, 'a.lua', 'new' } }, seen)
      assert.equal(tab, diff.tab())
      assert.same({ 'a.lua', 'new' }, { diff.locate(bufnr) })
      assert.same({ 'a.lua', 'old' }, { diff.locate(old) })
      assert.is_nil(diff.locate(h.buffer()))

      seen = {}
      diff.redraw()
      assert.equal(2, #seen)

      vim.cmd('tabfirst')
      assert.equal('shown', diff.open(session, 'a.lua'))
      assert.equal(tab, vim.api.nvim_get_current_tabpage())
      assert.equal(1, #runs)
    end)

    it('reads both sides from git for a file the change deletes', function()
      assert.equal('opened', diff.open(session, 'gone.lua'))
      assert.same(
        { { 'file', session.merge_base, session.pull.head_sha } },
        runs
      )
    end)

    it('reads both sides from git when lifecycle is gone', function()
      stub(package.loaded, 'codediff.ui.lifecycle', nil)
      stub(package.preload, 'codediff.ui.lifecycle', function() return 1 end)
      assert.equal('opened', diff.open(session, 'a.lua'))
      assert.same(
        { { 'file', session.merge_base, session.pull.head_sha } },
        runs
      )
      assert.is_true(
        said(
          'codediff changed: codediff.ui.lifecycle has no get_buffers or get_windows'
        )
      )
    end)

    it('retries with both revisions when one is refused', function()
      fail[1] = 'no such form'
      assert.equal('opened', diff.open(session, 'a.lua'))
      assert.equal(2, #runs)
      assert.same(
        { 'file', session.merge_base, session.pull.head_sha },
        runs[2]
      )
      assert.matches(
        'codediff changed: `:CodeDiff file <rev>` failed: .*no such form',
        notes[1]
      )
    end)

    it('says when the diff cannot be opened at all', function()
      fail[1], fail[2] = 'first', 'second'
      assert.is_false(diff.open(session, 'a.lua'))
      assert.matches(
        '^Could not open the diff of a.lua: .*second',
        notes[#notes]
      )
      -- Nothing is waited for any more
      local tab = codediff_opens()
      buffers[tab] = { virtual('a.lua'), nil }
      assert.same({}, seen)
      assert.is_nil(diff.tab())
    end)

    it('waits for codediff to record the buffers of a tab', function()
      stub(diff, 'CLAIM_INTERVAL', 1)
      diff.open(session, 'a.lua')
      local tab = codediff_opens()
      local old = virtual('a.lua')
      assert.is_nil(diff.tab())
      buffers[tab] = { old, nil }
      assert.is_true(vim.wait(1000, function() return diff.tab() == tab end))
      assert.same({ { old, 'a.lua', 'old' } }, seen)
    end)

    it('gives up on a tab that never records its buffers', function()
      stub(diff, 'CLAIM_INTERVAL', 1)
      stub(diff, 'CLAIM_TIMEOUT', 3)
      diff.open(session, 'a.lua')
      codediff_opens()
      local msg = 'codediff changed: a diff tab never recorded its buffers'
      assert.is_true(vim.wait(1000, function() return said(msg) end))
      assert.is_nil(diff.tab())
    end)

    it('stops waiting once the tab is closed', function()
      stub(diff, 'CLAIM_INTERVAL', 1)
      diff.open(session, 'a.lua')
      local asked = 0
      local get = lifecycle.get_buffers
      lifecycle.get_buffers = function(tab)
        asked = asked + 1
        return get(tab)
      end
      codediff_opens()
      vim.cmd('tabclose')
      local before = asked
      vim.wait(20)
      assert.equal(before, asked)
      assert.is_nil(diff.tab())
    end)

    it('leaves a tab of another file alone', function()
      diff.open(session, 'a.lua')
      local tab = codediff_opens()
      buffers[tab] = { virtual('b.lua'), nil }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      assert.is_nil(diff.tab())
      assert.same({}, seen)
    end)

    it('ignores an open event without a tab', function()
      diff.open(session, 'a.lua')
      vim.api.nvim_exec_autocmds('User', { pattern = 'CodeDiffOpen' })
      assert.is_nil(diff.tab())
    end)

    it('says when get_buffers fails', function()
      diff.open(session, 'a.lua')
      vim.cmd('tabnew')
      local tab = vim.api.nvim_get_current_tabpage()
      buffers[tab] = 'boom'
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      assert.matches('codediff changed: get_buffers failed: .*boom', notes[1])
      assert.is_nil(diff.tab())
    end)

    it('closes the tab of the file shown before', function()
      h.write(dir .. '/wt/b.lua', { 'b' })
      diff.open(session, 'a.lua')
      vim.cmd('tabnew')
      local first = vim.api.nvim_get_current_tabpage()
      buffers[first] = { virtual('a.lua'), nil }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = first } }
      )
      assert.equal(first, diff.tab())

      diff.open(session, 'b.lua')
      vim.cmd('tabnew')
      local second = vim.api.nvim_get_current_tabpage()
      buffers[second] = { virtual('b.lua'), nil }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = second } }
      )
      assert.equal(second, diff.tab())
      assert.is_false(vim.api.nvim_tabpage_is_valid(first))
    end)

    it('hands a side over again once git fills it in', function()
      diff.open(session, 'a.lua')
      local bufnr = vim.fn.bufnr(dir .. '/wt/a.lua')
      local old = virtual('a.lua')
      vim.cmd('tabnew')
      local tab = vim.api.nvim_get_current_tabpage()
      buffers[tab] = { old, bufnr }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      seen = {}
      local function loaded(data)
        vim.api.nvim_exec_autocmds(
          'User',
          { pattern = 'CodeDiffVirtualFileLoaded', data = data }
        )
      end
      loaded({ buf = old })
      loaded({ buf = bufnr })
      loaded({ buf = h.buffer() })
      loaded(nil)
      assert.same({ { old, 'a.lua', 'old' }, { bufnr, 'a.lua', 'new' } }, seen)

      -- A buffer wiped meanwhile is not handed over
      seen = {}
      vim.api.nvim_buf_delete(old, { force = true })
      diff.redraw()
      assert.same({ { bufnr, 'a.lua', 'new' } }, seen)
    end)

    it('forgets the diff when codediff closes its tab', function()
      diff.open(session, 'a.lua')
      vim.cmd('tabnew')
      local tab = vim.api.nvim_get_current_tabpage()
      buffers[tab] = { virtual('a.lua'), nil }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffClose', data = { tabpage = tab + 1000 } }
      )
      assert.equal(tab, diff.tab())
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffClose', data = { tabpage = tab } }
      )
      assert.is_nil(diff.tab())
      assert.is_nil(diff.locate(vim.fn.bufnr(dir .. '/wt/a.lua')))
      seen = {}
      diff.redraw()
      assert.same({}, seen)
    end)

    describe('window', function()
      local tab

      before_each(function()
        diff.open(session, 'a.lua')
        vim.cmd('tabnew')
        tab = vim.api.nvim_get_current_tabpage()
        buffers[tab] = { virtual('a.lua'), nil }
        vim.api.nvim_exec_autocmds(
          'User',
          { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
        )
      end)

      it('gives the window of each side', function()
        local win = vim.api.nvim_get_current_win()
        windows[tab] = { win, nil }
        assert.equal(win, diff.window('old'))
        assert.is_nil(diff.window('new'))
      end)

      it('says when get_windows fails', function()
        windows[tab] = 'broken'
        assert.is_nil(diff.window('old'))
        assert.matches(
          'codediff changed: get_windows failed: .*broken',
          notes[#notes]
        )
      end)

      it('gives none when lifecycle is gone', function()
        stub(package.loaded, 'codediff.ui.lifecycle', {})
        assert.is_nil(diff.window('old'))
        assert.matches('codediff.ui.lifecycle has no', notes[#notes])
      end)

      it('gives none once the tab is closed', function()
        diff.close()
        assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
        assert.is_nil(diff.window('old'))
        assert.is_nil(diff.tab())
      end)
    end)

    it('keeps a tab open when it closes the last one', function()
      vim.cmd('silent! tabonly!')
      diff.open(session, 'a.lua')
      local tab = vim.api.nvim_get_current_tabpage()
      buffers[tab] = { virtual('a.lua'), nil }
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'CodeDiffOpen', data = { tabpage = tab } }
      )
      assert.equal(tab, diff.tab())
      diff.close()
      assert.is_false(vim.api.nvim_tabpage_is_valid(tab))
      assert.equal(1, #vim.api.nvim_list_tabpages())
      -- Closing again does nothing
      diff.close()
      assert.equal(1, #vim.api.nvim_list_tabpages())
    end)
  end)
end)
