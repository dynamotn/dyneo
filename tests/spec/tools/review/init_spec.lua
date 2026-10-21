local h = require('helpers')

describe('tools.review', function()
  local review, git, forge, untrusted, diff, panel, store, plugin, session
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
      'tools.review.session',
      'tools.review.actions',
      'tools.review.pickers',
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

    session = require('tools.review.session')
    stub(session, 'repo_root', function(cb) cb(root) end)
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
    stub(git, 'worktree_remove', function(_, dir, cb)
      rec('worktree_remove')
      vim.fn.delete(dir, 'rf')
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
    stub(store, 'lock', function() return true end)
    stub(store, 'unlock', function() rec('unlock') end)
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

    it('refuses a review another Neovim has open', function()
      stub(
        store,
        'lock',
        function() return false, 'This review is open in another Neovim (pid 1)' end
      )
      review.open(remote, pull())
      assert.is_nil(review.current())
      assert.same({}, calls)
      assert.is_truthy(
        said(vim.log.levels.ERROR)[1]:find('another Neovim (pid 1)', 1, true)
      )
    end)

    it('removes the worktree when the open fails after making it', function()
      stub(store, 'load', function() error('disk broke') end)
      review.open(remote, pull())
      assert.is_nil(review.current())
      local after = vim.list_slice(calls, #calls - 4)
      assert.same(
        { 'worktree_add', 'hold', 'unlock', 'worktree_remove', 'forget' },
        after
      )
    end)

    it('keeps a worktree git will not remove held, saying where', function()
      stub(store, 'load', function() error('disk broke') end)
      stub(git, 'worktree_remove', function(_, _, cb)
        rec('worktree_remove')
        cb(false, 'it is locked')
      end)
      review.open(remote, pull())
      assert.is_false(vim.tbl_contains(calls, 'forget'))
      local warning = table.concat(said(vim.log.levels.WARN), '\n')
      assert.is_truthy(warning:find('dyreview-github-7', 1, true))
      assert.is_truthy(warning:find('it is locked', 1, true))
    end)

    it('lets the lock go when the open fails', function()
      stub(git, 'fetch', function(_, _, _, cb) cb(false, 'no network') end)
      review.open(remote, pull())
      assert.is_nil(review.current())
      assert.same({ 'unlock' }, calls)
    end)

    it('lets the lock go on close and when Neovim leaves', function()
      review.open(remote, pull())
      vim.api.nvim_exec_autocmds('VimLeavePre', {})
      assert.equals('unlock', calls[#calls])
      calls = {}
      review.close()
      assert.is_true(vim.tbl_contains(calls, 'unlock'))
    end)

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

    for _, case in ipairs({
      { kind = 'github', posted = '302/501', comment = 501 },
      { kind = 'gitlab', posted = 'draft:61', comment = 61 },
    }) do
      it(
        'imports a draft posted from here only once on ' .. case.kind,
        function()
          local adapter_of = require('tools.review.forge.' .. case.kind)
          local imported_id =
            vim.fn.sha256(case.kind .. ':' .. case.comment):sub(1, 12)
          local mine = {
            id = 'mine',
            origin = 'user',
            state = 'ready',
            path = 'a.lua',
            side = 'new',
            line = 1,
            body = 'x',
            posted = case.posted,
          }
          stub(
            store,
            'load',
            function() return { reviewed = {}, drafts = { mine } } end
          )
          adapter.import_id = adapter_of.import_id
          adapter.pending = function(_, _, cb)
            cb({
              {
                id = imported_id,
                origin = 'forge',
                state = 'ready',
                path = 'a.lua',
                side = 'new',
                line = 1,
                body = 'x',
              },
              {
                id = 'other',
                origin = 'forge',
                state = 'ready',
                path = 'b.lua',
                side = 'new',
                line = 2,
                body = 'y',
              },
            })
          end
          review.open(remote, pull())
          assert.same(
            { 'mine', 'other' },
            vim.tbl_map(
              function(d) return d.id end,
              review.current().state.drafts
            )
          )
        end
      )
    end

    it('writes down the head a draft was imported on', function()
      adapter.pending = function(_, _, cb)
        cb({
          {
            id = 'f',
            origin = 'forge',
            state = 'ready',
            path = 'a.lua',
            side = 'new',
            line = 1,
            body = 'x',
          },
        })
      end
      review.open(remote, pull())
      assert.equals(head, review.current().state.drafts[1].head)
    end)

    it('keeps why the pull request is read only', function()
      review.open(remote, pull({ read_only = 'The pull request is merged' }))
      assert.equals('The pull request is merged', review.current().blocked)
    end)

    it(
      'says why a pull request whose code cannot be fetched cannot open',
      function()
        local why = 'the source branch lives in a fork that cannot be fetched'
        review.open(remote, pull({ read_only = why, unfetchable = why }))
        assert.is_nil(review.current())
        assert.same({}, calls)
        assert.same({ why .. ': nothing to show' }, said(vim.log.levels.WARN))
        -- Nothing is left opening: the next pull request opens
        review.open(remote, pull({ id = '8' }))
        assert.equals('8', review.current().pull.id)
      end
    )

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
      assert.is_true(
        vim.wait(
          1000,
          function() return not vim.api.nvim_buf_is_valid(editor) end
        )
      )
    end)

    it('closes only the float on :wq, leaving the other windows', function()
      vim.cmd('vsplit')
      local wins = vim.api.nvim_tabpage_list_wins(0)
      local before = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      review.comment()
      local editor = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'ok' })
      vim.cmd('wq')
      vim.wait(50)
      assert.equals('ok', review.current().state.drafts[1].body)
      assert.is_false(vim.api.nvim_buf_is_valid(editor))
      assert.same(wins, vim.api.nvim_tabpage_list_wins(0))
      assert.equals(before, vim.api.nvim_get_current_win())
      vim.cmd('only')
    end)

    it('keeps a comment inside a hunk on its line', function()
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      review.comment()
      assert.same({}, said(vim.log.levels.WARN))
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'ok' })
      vim.cmd('write')
      local draft = review.current().state.drafts[1]
      assert.is_nil(draft.file_level)
      assert.equals(head, draft.head)
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

    it('acts on the shown draft, not a dropped AI one beside it', function()
      local mine = {
        id = 'u1',
        origin = 'user',
        state = 'ready',
        path = 'src/auth.lua',
        side = 'new',
        line = 3,
        body = 'mine',
      }
      local dropped = vim.tbl_extend(
        'force',
        mine,
        { id = 'a1', origin = 'ai', state = 'dropped', body = 'ai' }
      )
      review.current().state.drafts = { mine, dropped }
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review.ai_action('drop')
      assert.equals('dropped', mine.state)
      review.current().state.drafts = { dropped }
      notes = {}
      review.ai_action('drop')
      assert.equals('No draft on this line', said(vim.log.levels.WARN)[1])
    end)

    it('resolves with a fresh draft beside a dropped reply', function()
      local s = review.current()
      s.threads = {
        {
          id = 't1',
          path = 'src/auth.lua',
          side = 'new',
          line = 3,
          resolved = false,
          comments = {},
        },
      }
      local dropped = {
        id = 'u1',
        origin = 'user',
        state = 'dropped',
        path = 'src/auth.lua',
        side = 'new',
        line = 3,
        body = 'never mind',
        reply_to = 't1',
      }
      s.state.drafts = { dropped }
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      review.toggle_resolve()
      assert.is_nil(dropped.resolve)
      local resolving = s.state.drafts[2]
      assert.is_true(resolving.resolve)
      assert.equals('ready', resolving.state)
      assert.equals('t1', resolving.reply_to)
    end)

    it('marks a file reviewed at its blob, and unmarks it', function()
      review.mark('src/auth.lua')
      assert.equals('blob1', review.current().state.reviewed['src/auth.lua'])
      review.mark('src/auth.lua')
      assert.is_nil(review.current().state.reviewed['src/auth.lua'])
    end)
  end)

  describe('a new push', function()
    it('closes the old head and opens the new one', function()
      review.open(remote, pull())
      calls = {}
      local moved = ('d'):rep(40)
      review.open(remote, pull({ head_sha = moved }))
      assert.is_true(
        vim.tbl_contains(
          vim.tbl_map(function(n) return n.msg end, notes),
          'The pull request moved to ddddddd: opening the new head'
        )
      )
      assert.is_true(vim.tbl_contains(calls, 'worktree_remove'))
      assert.is_true(vim.tbl_contains(calls, 'fetch'))
      assert.equals(moved, review.current().pull.head_sha)
    end)

    it('stays on the old head when the review cannot close', function()
      review.open(remote, pull())
      local s = review.current()
      local bufnr = h.buffer({
        name = vim.fs.joinpath(s.worktree, 'src', 'auth.lua'),
        lines = { 'x' },
      })
      vim.bo[bufnr].modified = true
      calls = {}
      review.open(remote, pull({ head_sha = ('d'):rep(40) }))
      assert.equals(s, review.current())
      assert.is_false(vim.tbl_contains(calls, 'fetch'))
      assert.is_truthy(said(vim.log.levels.WARN)[1]:find('auth.lua', 1, true))
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)
  end)

  describe('threads', function()
    it('says when they could not be read', function()
      adapter.threads = function(_, _, cb) cb(nil, 'HTTP 500') end
      review.open(remote, pull())
      assert.is_truthy(review.current().threads_error:find('HTTP 500', 1, true))
    end)
  end)

  describe('drafts and close', function()
    local bufnr

    before_each(function()
      review.open(remote, pull())
      bufnr = h.buffer({ lines = vim.fn['repeat']({ 'x' }, 20) })
      vim.api.nvim_set_current_buf(bufnr)
      stub(diff, 'locate', function(b)
        if b == bufnr then return 'src/auth.lua', 'new' end
      end)
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
    end)

    after_each(function()
      for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):find('dyreview://', 1, true) then
          vim.bo[b].modified = false
          pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
      end
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it('refuses to close while a draft is being written', function()
      local s = review.current()
      review.comment()
      local editor = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'half' })
      review.close()
      assert.equals(s, review.current())
      local warning = said(vim.log.levels.WARN)[1]
      assert.is_truthy(warning:find(vim.api.nvim_buf_get_name(editor), 1, true))
      assert.is_false(vim.tbl_contains(calls, 'worktree_remove'))
    end)

    it('stores a draft written after its review closed', function()
      review.comment()
      local editor = vim.api.nvim_get_current_buf()
      review.close()
      assert.is_nil(review.current())
      local saved
      stub(
        store,
        'save',
        function(r, id, state) saved = { remote = r, id = id, state = state } end
      )
      vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'late' })
      vim.cmd('write')
      assert.equals('7', saved.id)
      assert.equals('o/r', saved.remote.slug)
      assert.equals('late', saved.state.drafts[1].body)
    end)

    --- Open the edit float on the draft at line 2 and hand back its buffer
    local function edit(draft)
      review.current().state.drafts = { draft }
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      review.ai_action('edit')
      return vim.api.nvim_get_current_buf()
    end

    it('shows the suggestion of an AI draft when editing it', function()
      local editor = edit({
        id = 'a1',
        origin = 'ai',
        state = 'pending',
        path = 'src/auth.lua',
        side = 'new',
        line = 2,
        body = 'Quote it.',
        suggestion = { 's = "```"' },
      })
      -- Fenced longer than any run of backticks it holds
      assert.same({
        'Quote it.',
        '',
        '````suggestion',
        's = "```"',
        '````',
      }, vim.api.nvim_buf_get_lines(editor, 0, -1, false))
      vim.api.nvim_buf_set_lines(
        editor,
        0,
        -1,
        false,
        { 'Quote it twice.', '', '````suggestion', 's = 1', '````' }
      )
      vim.cmd('write')
      local draft = review.current().state.drafts[1]
      assert.equals('Quote it twice.', draft.body)
      assert.same({ 's = 1' }, draft.suggestion)
      assert.equals('edited', draft.state)
    end)

    it('drops a suggestion taken out of the float', function()
      local editor = edit({
        id = 'a1',
        origin = 'ai',
        state = 'pending',
        path = 'src/auth.lua',
        side = 'new',
        line = 2,
        body = 'Quote it.',
        suggestion = { 'x' },
      })
      vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'Only words.' })
      vim.cmd('write')
      local draft = review.current().state.drafts[1]
      assert.equals('Only words.', draft.body)
      assert.is_nil(draft.suggestion)
    end)

    it('keeps a suggestion typed into a draft of mine', function()
      local editor = edit({
        id = 'u1',
        origin = 'user',
        state = 'ready',
        path = 'src/auth.lua',
        side = 'new',
        line = 2,
        body = 'mine',
      })
      assert.same({ 'mine' }, vim.api.nvim_buf_get_lines(editor, 0, -1, false))
      vim.api.nvim_buf_set_lines(
        editor,
        0,
        -1,
        false,
        { 'mine', '```suggestion', 'z', '```' }
      )
      vim.cmd('write')
      local draft = review.current().state.drafts[1]
      assert.equals('mine', draft.body)
      assert.same({ 'z' }, draft.suggestion)
    end)

    it('stores an edit finished after its review closed', function()
      local draft = {
        id = 'a1',
        origin = 'ai',
        state = 'pending',
        path = 'src/auth.lua',
        side = 'new',
        line = 2,
        body = 'old',
      }
      review.current().state.drafts = { draft }
      review.ai_action('edit')
      local editor = vim.api.nvim_get_current_buf()
      review.close()
      local saved
      stub(
        store,
        'load',
        function() return { reviewed = {}, drafts = { vim.deepcopy(draft) } } end
      )
      stub(store, 'save', function(_, _, state) saved = state end)
      vim.api.nvim_buf_set_lines(editor, 0, -1, false, { 'new words' })
      vim.cmd('write')
      assert.equals('new words', saved.drafts[1].body)
      assert.equals('edited', saved.drafts[1].state)
    end)
  end)

  describe('branch', function()
    local origin = vim.tbl_extend('force', remote, { name = 'origin' })
    local upstream =
      vim.tbl_extend('force', remote, { name = 'upstream', slug = 'u/r' })
    local mirror =
      vim.tbl_extend('force', remote, { name = 'mirror', slug = 'm/r' })
    local has, asked, opened

    before_each(function()
      has, asked, opened = {}, nil, nil
      stub(require('util.forge'), 'branch', function(_, cb) cb('feature') end)
      stub(session, 'tracked_remote', function(_, _, cb) cb('origin') end)
      stub(
        session,
        'remotes',
        function(_, cb) cb({ mirror, origin, upstream }) end
      )
      stub(forge, 'for_remote', function(r)
        return {
          for_branch = function(_, _, cb)
            cb(has[r.name] and pull({ id = has[r.name] }) or nil)
          end,
        }
      end)
      stub(vim.ui, 'select', function(items) asked = items end)
      stub(session, 'open', function(r, p) opened = { r.name, p.id } end)
    end)

    it('opens the pull request of the tracked remote', function()
      has = { origin = '3', upstream = '9' }
      review.branch()
      assert.same({ 'origin', '3' }, opened)
      assert.is_nil(asked)
    end)

    it('never opens another remote pull request without asking', function()
      has = { upstream = '9' }
      review.branch()
      assert.is_nil(opened)
      assert.equals(1, #asked)
    end)

    it('asks which when two other remotes have one', function()
      has = { upstream = '9', mirror = '4' }
      review.branch()
      assert.is_nil(opened)
      assert.equals(2, #asked)
    end)

    it('takes origin when the branch tracks no remote', function()
      local alice = vim.tbl_extend('force', remote, {
        name = 'alice',
        slug = 'a/r',
      })
      stub(session, 'tracked_remote', function(_, _, cb) cb(nil) end)
      stub(session, 'remotes', function(_, cb) cb({ alice, origin }) end)
      has = { alice = '5', origin = '3' }
      review.branch()
      assert.same({ 'origin', '3' }, opened)
      assert.is_nil(asked)
    end)

    it('asks when no remote is the one to use', function()
      local alice = vim.tbl_extend('force', remote, {
        name = 'alice',
        slug = 'a/r',
      })
      stub(session, 'tracked_remote', function(_, _, cb) cb(nil) end)
      stub(session, 'remotes', function(_, cb) cb({ alice }) end)
      has = { alice = '5' }
      review.branch()
      assert.is_nil(opened)
      assert.equals(1, #asked)
    end)
  end)

  describe('command', function()
    it('hands ai to the AI pass', function()
      local got = {}
      local ai = require('tools.review.ai')
      stub(ai, 'run', function(s) got[#got + 1] = s or 'none' end)
      review.command({ fargs = { 'ai' } })
      assert.same({ 'none' }, got)
    end)

    it('hands submit to the submit module', function()
      local got = {}
      local submit = require('tools.review.submit')
      stub(submit, 'run', function(s) got[#got + 1] = s or 'none' end)
      review.command({ fargs = { 'submit' } })
      assert.same({ 'none' }, got)
    end)

    it('asks for a review first', function()
      review.command({ fargs = { 'drafts' } })
      assert.is_truthy(said(vim.log.levels.WARN)[1]:find('No review', 1, true))
    end)
  end)
end)
