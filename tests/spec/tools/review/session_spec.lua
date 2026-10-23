local h = require('helpers')

describe('tools.review.session', function()
  local session, git, forge, untrusted, diff, panel, store, system, ci
  local root, cleanup, calls, notes, restore, adapter, real_repo_root

  local remote =
    { name = 'origin', host = 'github.com', slug = 'o/r', kind = 'github' }
  local head = ('c'):rep(40)

  local function pull(fields)
    return vim.tbl_extend('force', {
      id = '7',
      title = 'feat: x',
      author = 'alice',
      base_sha = ('b'):rep(40),
      head_sha = head,
      fetch = { '+refs/pull/7/head:refs/dyneo/review/github-7/head' },
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

  --- Where the worktree of pull request 7 goes
  local function worktree_dir()
    return vim.fs.joinpath(root, '.worktrees', 'dyreview-github-7')
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
      'tools.review.ci',
      'util.untrusted'
    )
    session = require('tools.review.session')
    git = require('tools.review.git')
    forge = require('tools.review.forge')
    untrusted = require('util.untrusted')
    diff = require('tools.review.diff')
    panel = require('tools.review.panel')
    store = require('tools.review.store')
    ci = require('tools.review.ci')
    system = require('util.system')
    root, cleanup = h.tmpdir()
    calls, notes, restore = {}, {}, {}

    real_repo_root = session.repo_root
    stub(session, 'repo_root', function(cb) cb(root) end)
    stub(git, 'fetch', function(_, _, _, cb) cb(true) end)
    stub(git, 'merge_base', function(_, _, _, cb) cb(('a'):rep(40)) end)
    stub(
      git,
      'files',
      function(_, _, _, cb)
        cb({
          {
            path = 'src/auth.lua',
            status = 'M',
            added = 3,
            removed = 1,
            attrs = { generated = false, vendored = false },
          },
        })
      end
    )
    stub(
      git,
      'hunks',
      function(_, _, _, _, _, cb) cb({ old = {}, new = { { 1, 3 } } }) end
    )
    stub(
      git,
      'blobs',
      function(_, _, _, cb) cb({ ['src/auth.lua'] = 'blob1' }) end
    )
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
    stub(git, 'delete_refs', function(_, _, _, cb) cb({}) end)
    adapter = {
      threads = function(_, _, cb) cb({}) end,
      pending = function(_, _, cb) cb({}) end,
    }
    stub(forge, 'for_remote', function() return adapter end)
    stub(untrusted, 'hold', function() rec('hold') end)
    stub(untrusted, 'release', function() rec('release') end)
    stub(untrusted, 'forget', function() rec('forget') end)
    stub(diff, 'on_buffer', function() end)
    stub(diff, 'open', function() return 'opened' end)
    stub(diff, 'close', function() end)
    stub(diff, 'redraw', function() end)
    stub(diff, 'locate', function() return nil end)
    stub(panel, 'open', function() end)
    stub(panel, 'refresh', function() end)
    stub(panel, 'follow', function() end)
    stub(panel, 'close', function() end)
    stub(ci, 'load', function() rec('ci') end)
    stub(store, 'load', function() return { reviewed = {}, drafts = {} } end)
    stub(store, 'save', function() end)
    stub(store, 'lock', function() return true end)
    stub(store, 'unlock', function() rec('unlock') end)
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

  describe('need', function()
    it('says how to start a review when none is open', function()
      assert.is_nil(session.need())
      assert.same(
        { 'No review is open: `:DyReview` picks one' },
        said(vim.log.levels.WARN)
      )
    end)

    it('gives the open review', function()
      session.open(remote, pull())
      assert.equals(session.current(), session.need())
      assert.same({}, said(vim.log.levels.WARN))
    end)
  end)

  describe('save', function()
    it('says a failed write and keeps the state in memory', function()
      session.open(remote, pull())
      local s = session.current()
      stub(store, 'save', function() error('disk full') end)
      s.state.reviewed['src/auth.lua'] = 'blob1'
      session.save(s)
      local errors = said(vim.log.levels.ERROR)
      assert.equals(1, #errors)
      assert.truthy(errors[1]:find('Could not save the review: ', 1, true))
      assert.truthy(errors[1]:find('disk full', 1, true))
      assert.equals('blob1', s.state.reviewed['src/auth.lua'])
    end)
  end)

  describe('under', function()
    it('compares with a separator', function()
      assert.is_true(session.under('/x/proj', '/x/proj/a.lua'))
      assert.is_false(session.under('/x/proj', '/x/proj-other/a.lua'))
      assert.is_false(session.under('/x/proj', '/x/proj'))
    end)

    it('resolves symlinks on both sides', function()
      local real = vim.fs.joinpath(root, 'real')
      vim.fn.mkdir(real, 'p')
      h.write(vim.fs.joinpath(real, 'a.lua'))
      local link = vim.fs.joinpath(root, 'link')
      assert(vim.uv.fs_symlink(real, link))
      assert.is_true(session.under(real, vim.fs.joinpath(link, 'a.lua')))
      assert.is_true(session.under(link, vim.fs.joinpath(real, 'a.lua')))
    end)
  end)

  describe('start_dir', function()
    local bufnr

    after_each(function()
      if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
    end)

    it("is the current file's directory", function()
      local sub = vim.fs.joinpath(root, 'sub')
      vim.fn.mkdir(sub, 'p')
      bufnr = h.buffer({ name = vim.fs.joinpath(sub, 'a.lua') })
      vim.api.nvim_set_current_buf(bufnr)
      assert.equals(sub, session.start_dir())
    end)

    it('is the cwd when that directory is gone', function()
      bufnr = h.buffer({ name = vim.fs.joinpath(root, 'gone', 'a.lua') })
      vim.api.nvim_set_current_buf(bufnr)
      assert.equals(vim.uv.cwd(), session.start_dir())
    end)
  end)

  describe('git_line', function()
    local ran, result

    before_each(function()
      ran, result = nil, nil
      stub(system, 'run', function(cmd, opts, cb)
        ran = { cmd = cmd, opts = opts }
        cb(result)
      end)
    end)

    local function line(answer)
      result = answer
      local got = 'unset'
      session.git_line(
        '/repo',
        { 'rev-parse', 'HEAD' },
        function(out) got = out end
      )
      return got
    end

    it('runs git in the directory and gives its first line', function()
      assert.equals('first', line({ code = 0, stdout = '  first\nsecond\n' }))
      assert.same({ 'git', 'rev-parse', 'HEAD' }, ran.cmd)
      assert.equals('/repo', ran.opts.cwd)
      assert.equals(git.TIMEOUT, ran.opts.timeout)
    end)

    it('gives nil on a failure or no output', function()
      assert.is_nil(line({ code = 128, stdout = 'fatal\n' }))
      assert.is_nil(line({ code = 0, stdout = '\n' }))
      assert.is_nil(line({ code = 0 }))
    end)
  end)

  describe('repo_root', function()
    local answer, asked

    before_each(function()
      -- What is tested here, not the stand-in every open uses
      stub(session, 'repo_root', real_repo_root)
      stub(session, 'start_dir', function() return '/work/repo/src' end)
      stub(session, 'git_line', function(dir, args, cb)
        asked = { dir = dir, args = args }
        cb(answer)
      end)
    end)

    local function repo_root()
      local got = {}
      session.repo_root(function(dir, err) got = { dir = dir, err = err } end)
      return got
    end

    it('is the directory holding the common .git', function()
      answer = '/work/repo/.git'
      assert.same({ dir = '/work/repo' }, repo_root())
      assert.equals('/work/repo/src', asked.dir)
      assert.same(
        { 'rev-parse', '--path-format=absolute', '--git-common-dir' },
        asked.args
      )
    end)

    it('says when there is no repository', function()
      answer = nil
      assert.same({ err = 'not in a git repository' }, repo_root())
    end)

    it('refuses a bare repository', function()
      answer = '/srv/repo.git'
      assert.same(
        { err = 'a bare repository has no checkout for a worktree' },
        repo_root()
      )
    end)
  end)

  describe('rev_parse and tracked_remote', function()
    local asked

    before_each(function()
      stub(session, 'git_line', function(dir, args, cb)
        asked = { dir = dir, args = args }
        cb('answer')
      end)
    end)

    it('verifies a commit, never reading the name as an option', function()
      local got
      session.rev_parse('/wt', '--all', function(sha) got = sha end)
      assert.equals('answer', got)
      assert.same({
        dir = '/wt',
        args = {
          'rev-parse',
          '--verify',
          '--quiet',
          '--end-of-options',
          '--all^{commit}',
        },
      }, asked)
    end)

    it('reads the remote a branch tracks', function()
      local got
      session.tracked_remote('/repo', 'feature', function(name) got = name end)
      assert.equals('answer', got)
      assert.same({
        dir = '/repo',
        args = { 'config', '--get', 'branch.feature.remote' },
      }, asked)
    end)
  end)

  describe('remotes', function()
    it('keeps one remote per repository on a known forge', function()
      local ran
      stub(system, 'run', function(cmd, opts, cb)
        ran = { cmd = cmd, opts = opts }
        cb({
          code = 0,
          stdout = table.concat({
            'remote.origin.url git@github.com:o/r.git',
            'remote.fork.url https://gitlab.example.com/g/p.git',
            'remote.az.url https://dev.azure.com/org/proj/_git/repo',
            'remote.dup.url https://github.com/o/r',
            'remote.local.url /srv/git/x.git',
            'remote.upstream.url https://github.com/u/r',
          }, '\n'),
        })
      end)
      local got
      session.remotes('/repo', function(found) got = found end)
      assert.same(
        { 'git', 'config', '--get-regexp', [[^remote\..*\.url$]] },
        ran.cmd
      )
      assert.equals('/repo', ran.opts.cwd)
      assert.same({
        {
          name = 'fork',
          host = 'gitlab.example.com',
          slug = 'g/p',
          kind = 'gitlab',
        },
        { name = 'origin', host = 'github.com', slug = 'o/r', kind = 'github' },
        {
          name = 'upstream',
          host = 'github.com',
          slug = 'u/r',
          kind = 'github',
        },
      }, got)
    end)

    it('gives none when git answers nothing', function()
      stub(system, 'run', function(_, _, cb) cb({ code = 1 }) end)
      local got
      session.remotes('/repo', function(found) got = found end)
      assert.same({}, got)
    end)
  end)

  describe('open', function()
    it('waits while a review is being sent', function()
      stub(package.loaded, 'tools.review.submit', {
        busy = function() return true end,
      })
      session.open(remote, pull())
      assert.is_nil(session.current())
      assert.same(
        { 'A review is being sent: wait for it to finish' },
        said(vim.log.levels.WARN)
      )
    end)

    it('says why a head that cannot be fetched is not opened', function()
      session.open(remote, pull({ unfetchable = 'The fork is gone' }))
      assert.is_nil(session.current())
      assert.same(
        { 'The fork is gone: nothing to show' },
        said(vim.log.levels.WARN)
      )
    end)

    it('says why a forge has no adapter', function()
      stub(forge, 'for_remote', function() return nil, 'no token' end)
      session.open(remote, pull())
      stub(forge, 'for_remote', function() return nil end)
      session.open(remote, pull())
      assert.is_nil(session.current())
      assert.same(
        { 'github: no token', 'github: no adapter' },
        said(vim.log.levels.WARN)
      )
      -- Nothing was left opening
      stub(forge, 'for_remote', function() return adapter end)
      session.open(remote, pull())
      assert.is_not_nil(session.current())
    end)

    for _, case in ipairs({
      {
        what = 'the changed files',
        target = 'files',
        fn = function(_, _, _, cb) cb(nil, 'bad range') end,
        message = 'Could not list the changed files: bad range',
      },
      {
        what = 'the files',
        target = 'blobs',
        fn = function(_, _, _, cb) cb(nil, 'cat-file died') end,
        message = 'Could not read the files: cat-file died',
      },
      {
        what = 'the worktree',
        target = 'worktree_add',
        fn = function(_, _, _, cb) cb(false, 'disk full') end,
        message = 'Could not make the worktree: disk full',
      },
    }) do
      it('stops when it cannot get ' .. case.what, function()
        stub(git, case.target, case.fn)
        session.open(remote, pull())
        assert.is_nil(session.current())
        assert.same({ case.message }, said(vim.log.levels.ERROR))
        assert.equals('unlock', calls[#calls])
        assert.is_false(vim.tbl_contains(calls, 'hold'))
      end)
    end

    it('takes the worktree an earlier session left at the head', function()
      vim.fn.mkdir(worktree_dir(), 'p')
      local asked
      stub(session, 'rev_parse', function(dir, rev, cb)
        asked = { dir, rev }
        cb(head)
      end)
      session.open(remote, pull())
      assert.same({ worktree_dir(), 'HEAD' }, asked)
      assert.is_false(vim.tbl_contains(calls, 'worktree_add'))
      assert.equals(worktree_dir(), session.current().worktree)
      assert.equals('ci', calls[#calls])
    end)

    it('refuses a worktree left at another head', function()
      vim.fn.mkdir(worktree_dir(), 'p')
      stub(session, 'rev_parse', function(_, _, cb) cb(('d'):rep(40)) end)
      session.open(remote, pull())
      assert.is_nil(session.current())
      assert.same({
        'Could not make the worktree: '
          .. worktree_dir()
          .. ' holds another version of the pull request: remove it with `git worktree remove`',
      }, said(vim.log.levels.ERROR))
      -- Not this session's to remove
      assert.is_false(vim.tbl_contains(calls, 'worktree_remove'))
      assert.equals(1, vim.fn.isdirectory(worktree_dir()))
    end)
  end)

  describe('same', function()
    it('matches host, slug and id', function()
      session.open(remote, pull())
      local s = session.current()
      assert.is_true(session.same(s, remote, '7'))
      assert.is_false(session.same(s, remote, '8'))
      assert.is_false(
        session.same(s, vim.tbl_extend('force', remote, { slug = 'o/x' }), '7')
      )
      assert.is_false(
        session.same(
          s,
          vim.tbl_extend('force', remote, { host = 'github.example.com' }),
          '7'
        )
      )
    end)
  end)

  describe('LspAttach', function()
    it('says once that the worktree has no dependencies', function()
      session.open(remote, pull())
      local outside = h.buffer({ name = vim.fs.joinpath(root, 'other.lua') })
      local inside =
        h.buffer({ name = vim.fs.joinpath(worktree_dir(), 'src', 'auth.lua') })
      local function attach(bufnr)
        vim.api.nvim_exec_autocmds(
          'LspAttach',
          { group = 'dy_review', buffer = bufnr, data = { client_id = 1 } }
        )
      end
      attach(outside)
      assert.same({}, notes)
      attach(inside)
      attach(inside)
      assert.same({
        'Dependencies are not installed in the review worktree: some servers answer only in part',
      }, vim.tbl_map(function(note) return note.msg end, notes))
      vim.api.nvim_buf_delete(outside, { force = true })
      vim.api.nvim_buf_delete(inside, { force = true })
    end)
  end)

  describe('close', function()
    it('waits while a review is being sent', function()
      session.open(remote, pull())
      stub(package.loaded, 'tools.review.submit', {
        busy = function() return true end,
      })
      assert.is_false(session.close())
      assert.is_not_nil(session.current())
    end)

    it('says there is nothing to close', function()
      assert.is_false(session.close())
      assert.same(
        { 'No review is open: `:DyReview` picks one' },
        said(vim.log.levels.WARN)
      )
    end)

    it('refuses while a worktree file holds unsaved text', function()
      session.open(remote, pull())
      local bufnr = h.buffer({
        name = vim.fs.joinpath(worktree_dir(), 'src', 'auth.lua'),
        lines = { 'changed' },
      })
      assert.is_true(vim.bo[bufnr].modified)
      assert.is_false(session.close())
      assert.is_not_nil(session.current())
      assert.truthy(
        said(vim.log.levels.WARN)[1]:find(
          'Not closed: unsaved changes in',
          1,
          true
        )
      )
      vim.api.nvim_buf_delete(bufnr, { force = true })
    end)

    it("takes the review's keys away and wipes its buffers", function()
      session.open(remote, pull())
      local s = session.current()
      local keyed = h.buffer({ lines = { 'a' } })
      s.keyed[keyed] = true
      s.keyed[99999] = true
      for _, key in ipairs(require('tools.review.actions').keys()) do
        vim.keymap.set(key[1], key[2], key[3], { buffer = keyed })
      end
      local inside = h.buffer({
        name = vim.fs.joinpath(worktree_dir(), 'src', 'auth.lua'),
      })
      local outside = h.buffer({ name = vim.fs.joinpath(root, 'other.lua') })
      local on_done = false
      assert.is_true(session.close(function() on_done = true end))
      assert.is_true(on_done)
      assert.is_nil(session.current())
      assert.same({}, vim.api.nvim_buf_get_keymap(keyed, 'n'))
      assert.same({}, vim.api.nvim_buf_get_keymap(keyed, 'x'))
      assert.is_false(vim.api.nvim_buf_is_valid(inside))
      assert.is_true(vim.api.nvim_buf_is_valid(outside))
      vim.api.nvim_buf_delete(keyed, { force = true })
      vim.api.nvim_buf_delete(outside, { force = true })
    end)

    it('says when the refs could not be deleted', function()
      stub(git, 'delete_refs', function(_, _, _, cb) cb(nil, 'ref locked') end)
      session.open(remote, pull())
      session.close()
      assert.same(
        { 'Could not delete the review refs: ref locked' },
        said(vim.log.levels.WARN)
      )
    end)

    it('says git refused to remove the worktree, with no reason', function()
      stub(git, 'worktree_remove', function(_, _, cb) cb(false) end)
      session.open(remote, pull())
      session.close()
      assert.same({
        ('Kept the review worktree at %s: git refused to remove it'):format(
          worktree_dir()
        ),
      }, said(vim.log.levels.WARN))
      assert.is_false(vim.tbl_contains(calls, 'forget'))
    end)
  end)
end)
