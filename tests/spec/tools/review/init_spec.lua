local h = require('helpers')

describe('tools.review', function()
  local review, git, forge, untrusted, diff, panel, store, plugin
  local root, cleanup, calls, notes, restore, adapter, on_buffer, maps

  local remote =
    { name = 'origin', host = 'github.com', slug = 'o/r', kind = 'github' }
  local head = ('c'):rep(40)

  local function pull(fields)
    return vim.tbl_extend('force', {
      id = '7',
      title = 'feat: x',
      author = 'alice',
      body = '',
      url = '',
      base_ref = 'main',
      head_ref = 'feature',
      base_sha = ('b'):rep(40),
      head_sha = head,
      fetch = { '+refs/pull/7/head:refs/dyneo/review/github-7/head' },
      fork = true,
    }, fields or {})
  end

  local function rec(name) calls[#calls + 1] = name end

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  --- The messages given at `level` or above
  local function said(level)
    return vim.tbl_map(
      function(note) return note.msg end,
      vim.tbl_filter(
        function(note) return (note.level or 0) >= level end,
        notes
      )
    )
  end

  before_each(function()
    h.unload(
      'tools.review',
      'tools.review.git',
      'tools.review.forge',
      'tools.review.panel',
      'tools.review.diff',
      'tools.review.store',
      'tools.review.drafts',
      'util.untrusted'
    )
    review = require('tools.review')
    git = require('tools.review.git')
    forge = require('tools.review.forge')
    untrusted = require('util.untrusted')
    diff = require('tools.review.diff')
    panel = require('tools.review.panel')
    store = require('tools.review.store')
    plugin = require('util.plugin')
    root, cleanup = h.tmpdir()
    calls, notes, restore, maps = {}, {}, {}, {}

    stub(review, 'repo_root', function(cb) cb(root) end)
    stub(git, 'fetch', function(_, _, _, cb)
      rec('fetch')
      cb(true)
    end)
    stub(git, 'merge_base', function(_, _, _, cb)
      rec('merge_base')
      cb(('a'):rep(40))
    end)
    stub(git, 'files', function(_, _, _, cb)
      rec('files')
      cb({
        {
          path = 'src/auth.lua',
          status = 'M',
          added = 3,
          removed = 1,
          binary = false,
          attrs = { generated = false, vendored = false },
        },
        {
          path = 'go.sum',
          status = 'M',
          added = 9,
          removed = 9,
          binary = false,
          attrs = { generated = false, vendored = false },
        },
      })
    end)
    stub(git, 'hunks', function(_, _, _, path, _, cb)
      rec('hunks ' .. path)
      cb({ old = { { 1, 2 } }, new = { { 1, 3 } } })
    end)
    stub(git, 'blobs', function(_, _, _, cb)
      rec('blobs')
      cb({ ['src/auth.lua'] = 'blob1', ['go.sum'] = 'blob2' })
    end)
    stub(git, 'worktree_add', function(_, dir, _, cb)
      rec('worktree_add')
      vim.fn.mkdir(dir, 'p')
      cb(true)
    end)
    stub(git, 'worktree_remove', function(_, _, cb)
      rec('worktree_remove')
      cb(true)
    end)
    stub(git, 'delete_refs', function(_, prefix, keep, cb)
      rec('delete_refs')
      calls.prefix, calls.keep = prefix, keep
      cb({})
    end)
    adapter = {
      threads = function(_, _, cb)
        rec('threads')
        cb({})
      end,
      pending = function(_, _, cb)
        rec('pending')
        cb({})
      end,
    }
    stub(forge, 'for_remote', function() return adapter end)
    stub(untrusted, 'hold', function(dir)
      -- No buffer of the worktree may exist before it is held
      for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        assert.is_false(vim.startswith(name, dir), name)
      end
      rec('hold')
    end)
    stub(untrusted, 'release', function() rec('release') end)
    stub(untrusted, 'forget', function() rec('forget') end)
    stub(diff, 'on_buffer', function(fn) on_buffer = fn end)
    stub(diff, 'open', function(_, path)
      rec('diff.open ' .. path)
      return 'opened'
    end)
    stub(diff, 'close', function() rec('diff.close') end)
    stub(diff, 'redraw', function() end)
    stub(diff, 'locate', function() return nil end)
    stub(panel, 'open', function() rec('panel.open') end)
    stub(panel, 'refresh', function() end)
    stub(panel, 'follow', function() end)
    stub(panel, 'close', function() rec('panel.close') end)
    stub(store, 'load', function() return { reviewed = {}, drafts = {} } end)
    stub(store, 'save', function() rec('save') end)
    stub(
      plugin,
      'safe_keymap_set',
      function(mode, lhs, _, opts)
        maps[#maps + 1] = { mode = mode, lhs = lhs, buffer = opts.buffer }
      end
    )
    stub(
      vim,
      'notify',
      function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    )
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_review')
    cleanup()
  end)

  describe('open', function()
    it(
      'fetches, reads the change, holds the worktree, then shows it',
      function()
        review.open(remote, pull())
        assert.same({
          'fetch',
          'merge_base',
          'files',
          'hunks src/auth.lua',
          'blobs',
          'worktree_add',
          'hold',
          'threads',
          'pending',
          'save',
          'diff.open src/auth.lua',
        }, calls)
        local s = review.current()
        assert.equals('source', s.files[1].kind)
        assert.equals('generated', s.files[2].kind)
        assert.is_true(s.files[1].risk > 0)
        assert.equals('blob1', s.files[1].blob)
        assert.equals(
          vim.fs.joinpath(root, '.worktrees', 'dyreview-github-7'),
          s.worktree
        )
        assert.is_false(s.trusted)
        assert.is_nil(s.blocked)
      end
    )

    it('shows the panel and gives the keys once the diff is up', function()
      review.open(remote, pull())
      local bufnr = h.buffer({ lines = { 'a', 'b', 'c' } })
      on_buffer(bufnr, 'src/auth.lua', 'new')
      assert.equals('panel.open', calls[#calls])
      local lhs = vim.tbl_map(function(m) return m.lhs end, maps)
      for _, key in ipairs({
        '<localleader>c',
        '<localleader>s',
        '<localleader>r',
        '<localleader>R',
        '<localleader>m',
        '<localleader>k',
        '<localleader>e',
        '<localleader>x',
        ']a',
        '[a',
      }) do
        assert.is_true(vim.tbl_contains(lhs, key), key)
      end
      local before = #maps
      on_buffer(bufnr, 'src/auth.lua', 'new')
      assert.equals(before, #maps)
    end)

    it('blocks sending when the pending review cannot be read', function()
      adapter.pending = function(_, _, cb) cb(nil, 'HTTP 502') end
      review.open(remote, pull())
      assert.is_truthy(review.current().blocked:find('HTTP 502', 1, true))
    end)

    it('keeps why the pull request is read only', function()
      review.open(remote, pull({ read_only = 'The pull request is merged' }))
      assert.equals('The pull request is merged', review.current().blocked)
    end)

    it('stops at a failed fetch, before any worktree', function()
      stub(git, 'fetch', function(_, _, _, cb) cb(false, 'no network') end)
      review.open(remote, pull())
      assert.is_nil(review.current())
      assert.is_false(vim.tbl_contains(calls, 'worktree_add'))
      assert.is_truthy(
        said(vim.log.levels.ERROR)[1]:find('no network', 1, true)
      )
    end)

    it('reuses the session of the same pull request', function()
      review.open(remote, pull())
      local s = review.current()
      local autocmds = #vim.api.nvim_get_autocmds({ group = 'dy_review' })
      calls = {}
      review.open(remote, pull())
      assert.equals(s, review.current())
      assert.same({ 'diff.open src/auth.lua' }, calls)
      assert.equals(
        autocmds,
        #vim.api.nvim_get_autocmds({ group = 'dy_review' })
      )
    end)
  end)

  describe('trust', function()
    it('asks once per pull request and head, naming a fork', function()
      local hold_first
      stub(untrusted, 'hold', function(_, fn) hold_first = fn end)
      local questions = {}
      stub(vim.fn, 'confirm', function(question)
        questions[#questions + 1] = question
        return 1
      end)
      review.open(remote, pull())
      hold_first(0)
      assert.same({
        "Review GitHub !7 by alice (from a fork): let language servers and the project's .nvim run its code?",
      }, questions)
      assert.is_true(review.current().trusted)
      assert.is_true(vim.tbl_contains(calls, 'release'))
    end)

    it('stays diff only on no', function()
      local hold_first
      stub(untrusted, 'hold', function(_, fn) hold_first = fn end)
      stub(vim.fn, 'confirm', function() return 2 end)
      review.open(remote, pull())
      hold_first(0)
      assert.is_false(review.current().trusted)
      assert.is_false(vim.tbl_contains(calls, 'release'))
    end)
  end)

  describe('close', function()
    it(
      'deletes the refs but the reviewed one, and removes the worktree',
      function()
        review.open(remote, pull())
        review.close()
        assert.is_nil(review.current())
        assert.equals('refs/dyneo/review/github-7/', calls.prefix)
        assert.same({ 'refs/dyneo/review/github-7/reviewed' }, calls.keep)
        assert.is_true(vim.tbl_contains(calls, 'worktree_remove'))
        assert.is_true(vim.tbl_contains(calls, 'forget'))
      end
    )

    it('keeps a worktree git refuses to remove, and says where', function()
      stub(
        git,
        'worktree_remove',
        function(_, _, cb) cb(false, 'contains modified or untracked files') end
      )
      review.open(remote, pull())
      local dir = review.current().worktree
      review.close()
      local warning = said(vim.log.levels.WARN)[1]
      assert.is_truthy(warning:find(dir, 1, true))
      assert.is_truthy(warning:find('contains modified', 1, true))
      assert.is_false(vim.tbl_contains(calls, 'forget'))
    end)
  end)

  describe('drafts at the cursor', function()
    local bufnr

    before_each(function()
      review.open(remote, pull())
      bufnr = h.buffer({ lines = vim.fn['repeat']({ 'x' }, 20) })
      vim.api.nvim_set_current_buf(bufnr)
      stub(diff, 'locate', function(b)
        if b == bufnr then return 'src/auth.lua', 'new' end
      end)
    end)

    after_each(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('warns at once and makes a file comment outside every hunk', function()
      vim.api.nvim_win_set_cursor(0, { 10, 0 })
      review.comment()
      assert.equals(
        'Outside the diff: sent as a file comment naming line 10',
        said(vim.log.levels.WARN)[1]
      )
      local editor = vim.api.nvim_get_current_buf()
      assert.equals('markdown', vim.bo[editor].filetype)
      vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'why?' })
      vim.cmd('write')
      local draft = review.current().state.drafts[1]
      assert.equals('why?', draft.body)
      assert.equals(10, draft.line)
      assert.is_true(draft.file_level)
      assert.is_false(vim.api.nvim_buf_is_valid(editor))
    end)

    it('keeps a comment inside a hunk on its line', function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      review.comment()
      assert.same({}, said(vim.log.levels.WARN))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'ok' })
      vim.cmd('write')
      local draft = review.current().state.drafts[1]
      assert.is_nil(draft.file_level)
      assert.equals('user', draft.origin)
    end)

    it('refuses to keep, edit or drop a draft pending on the forge', function()
      local draft = {
        id = 'f1',
        origin = 'forge',
        state = 'ready',
        path = 'src/auth.lua',
        side = 'new',
        line = 3,
        body = 'theirs',
      }
      review.current().state.drafts = { draft }
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      for _, action in ipairs({ 'keep', 'edit', 'drop' }) do
        notes = {}
        review.ai_action(action)
        local warning = said(vim.log.levels.WARN)[1]
        assert.is_truthy(warning and warning:find('forge', 1, true), action)
      end
      assert.equals('ready', draft.state)
      assert.equals('theirs', draft.body)
      assert.equals(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('keeps and drops an AI draft', function()
      local draft = {
        id = 'a1',
        origin = 'ai',
        state = 'pending',
        path = 'src/auth.lua',
        side = 'new',
        line = 3,
        body = 'look',
      }
      review.current().state.drafts = { draft }
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review.ai_action('keep')
      assert.equals('kept', draft.state)
      review.ai_action('drop')
      assert.equals('dropped', draft.state)
    end)

    it('marks a file reviewed at its blob, and unmarks it', function()
      review.mark('src/auth.lua')
      assert.equals('blob1', review.current().state.reviewed['src/auth.lua'])
      review.mark('src/auth.lua')
      assert.is_nil(review.current().state.reviewed['src/auth.lua'])
    end)
  end)

  describe('command', function()
    it('says not yet for what is still to come', function()
      review.command({ fargs = { 'submit' } })
      assert.is_truthy(notes[1].msg:find('not yet', 1, true))
    end)

    it('asks for a review first', function()
      review.command({ fargs = { 'drafts' } })
      assert.is_truthy(said(vim.log.levels.WARN)[1]:find('No review', 1, true))
    end)
  end)
end)
