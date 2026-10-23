local h = require('helpers')

describe('tools.review.pickers', function()
  local pickers, session, forge, git, panel, util_forge
  local notes, restore, picked, shown, opened, selected

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  --- The messages given, in order
  local function said()
    return vim.tbl_map(function(note) return note.msg end, notes)
  end

  --- A picker object that records it was closed
  local function fake_picker()
    local p = { closed = false }
    function p:close() self.closed = true end
    return p
  end

  before_each(function()
    h.unload(
      'tools.review.pickers',
      'tools.review.session',
      'tools.review.forge',
      'tools.review.git',
      'tools.review.panel'
    )
    session = require('tools.review.session')
    forge = require('tools.review.forge')
    git = require('tools.review.git')
    panel = require('tools.review.panel')
    util_forge = require('util.forge')
    pickers = require('tools.review.pickers')
    notes, restore, picked, shown, opened, selected = {}, {}, {}, {}, {}, {}
    stub(
      vim,
      'notify',
      function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    )
    stub(_G, 'Snacks', {
      picker = {
        pick = function(opts) picked[#picked + 1] = opts end,
      },
    })
    stub(package.loaded, 'tools.review', {
      show = function(path) shown[#shown + 1] = path end,
    })
    stub(
      session,
      'open',
      function(remote, pull) opened[#opened + 1] = { remote, pull } end
    )
    stub(vim.ui, 'select', function(items, opts, on_choice)
      selected[#selected + 1] = { items = items, opts = opts }
      on_choice(selected.choose and items[1] or nil)
    end)
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
  end)

  describe('draft_cells', function()
    local function draft(fields)
      return vim.tbl_extend('force', {
        id = 'd',
        origin = 'user',
        state = 'ready',
        path = 'a.lua',
        side = 'new',
        line = 3,
        body = 'First line\nsecond',
      }, fields or {})
    end

    it('shows origin, state, severity, place and first line', function()
      assert.same(
        { 'me', 'ready', '', 'a.lua:3', 'First line' },
        pickers.draft_cells(draft())
      )
      assert.same(
        { 'AI', 'pending', 'nit', 'a.lua:3', 'First line' },
        pickers.draft_cells(draft({
          origin = 'ai',
          state = 'pending',
          severity = 'nit',
        }))
      )
    end)

    it(
      'says a draft carries a suggestion',
      function()
        assert.same(
          { 'AI', 'pending', '', 'a.lua:3', 'First line + suggestion' },
          pickers.draft_cells(draft({
            origin = 'ai',
            state = 'pending',
            suggestion = { 'x' },
          }))
        )
      end
    )
  end)

  describe('drafts', function()
    it('does nothing without a session', function()
      stub(session, 'need', function() return nil end)
      pickers.drafts()
      assert.same({}, picked)
    end)

    it('says when there are no drafts', function()
      stub(session, 'need', function() return { state = { drafts = {} } } end)
      pickers.drafts()
      assert.same({}, picked)
      assert.same({ 'No drafts yet' }, said())
    end)

    it('lists drafts and jumps to the chosen one', function()
      local s = {
        state = {
          drafts = {
            {
              origin = 'ai',
              state = 'pending',
              severity = 'nit',
              path = 'a.lua',
              side = 'old',
              line = 4,
              body = 'Rename',
            },
          },
        },
      }
      stub(session, 'need', function() return s end)
      stub(session, 'current', function() return s end)
      pickers.drafts()
      local opts = picked[1]
      assert.equal('Review drafts', opts.title)
      local item = opts.items[1]
      assert.equal('AI pending nit a.lua:4 Rename', item.text)
      assert.same({
        { 'AI     ', 'SnacksPickerLabel' },
        { 'pending  ', 'SnacksPickerComment' },
        { 'nit         ', 'SnacksPickerComment' },
        { 'a.lua:4  ', false },
        { 'Rename  ', false },
      }, opts.format(item))

      local p = fake_picker()
      opts.confirm(p, item)
      assert.is_true(p.closed)
      assert.same({ path = 'a.lua', side = 'old', line = 4 }, s.jump)
      assert.same({ 'a.lua' }, shown)
    end)

    it('only closes the picker when nothing is chosen', function()
      local s = {
        state = {
          drafts = {
            { origin = 'user', state = 'ready', path = 'a', line = 1 },
          },
        },
      }
      stub(session, 'need', function() return s end)
      pickers.drafts()
      local p = fake_picker()
      picked[1].confirm(p, nil)
      assert.is_true(p.closed)
      assert.same({}, shown)
    end)
  end)

  describe('since', function()
    local s

    before_each(function()
      s = {
        root = '/repo',
        refs = 'refs/dyneo/review/github-7/',
        merge_base = 'mb',
        pull = { base_sha = 'base', head_sha = 'head' },
        files = { { path = 'a.lua' }, { path = 'b.lua' } },
      }
      stub(session, 'need', function() return s end)
      stub(session, 'current', function() return nil end)
    end)

    it('does nothing without a session', function()
      stub(session, 'need', function() return nil end)
      local asked = false
      stub(session, 'rev_parse', function() asked = true end)
      pickers.since()
      assert.is_false(asked)
    end)

    it('lists the files the interdiff names, and opens one', function()
      local args
      stub(session, 'rev_parse', function(dir, rev, cb)
        assert.equal('/repo', dir)
        assert.equal('refs/dyneo/review/github-7/reviewed', rev)
        cb('rev')
      end)
      stub(git, 'merge_base', function(_, a, b, cb)
        assert.same({ 'base', 'rev' }, { a, b })
        cb('oldbase')
      end)
      stub(git, 'interdiff', function(root, ob, r, mb, hd, cb)
        args = { root, ob, r, mb, hd }
        cb({ 'b.lua' })
      end)
      pickers.since()
      assert.same({ '/repo', 'oldbase', 'rev', 'mb', 'head' }, args)
      local opts = picked[1]
      assert.equal('Changed since your last review', opts.title)
      assert.same({ { text = 'b.lua', path = 'b.lua' } }, opts.items)
      assert.same({ { 'b.lua' } }, opts.format(opts.items[1]))
      opts.confirm(fake_picker(), opts.items[1])
      assert.same({ 'b.lua' }, shown)
    end)

    it('says when nothing changed', function()
      stub(session, 'rev_parse', function(_, _, cb) cb('rev') end)
      stub(git, 'merge_base', function(_, _, _, cb) cb('oldbase') end)
      stub(git, 'interdiff', function(_, _, _, _, _, cb) cb({}) end)
      pickers.since()
      assert.same({}, picked)
      assert.same({ 'Nothing changed since your last review' }, said())
    end)

    it('says when there is no merge base', function()
      stub(session, 'rev_parse', function(_, _, cb) cb('rev') end)
      stub(git, 'merge_base', function(_, _, _, cb) cb(nil, 'boom') end)
      pickers.since()
      assert.same({ 'No merge base: boom' }, said())
      assert.equal(vim.log.levels.ERROR, notes[1].level)
    end)

    it('says when the interdiff fails', function()
      stub(session, 'rev_parse', function(_, _, cb) cb('rev') end)
      stub(git, 'merge_base', function(_, _, _, cb) cb('oldbase') end)
      stub(git, 'interdiff', function(_, _, _, _, _, cb) cb(nil, 'bad') end)
      pickers.since()
      assert.same({ 'Could not compare: bad' }, said())
      assert.equal(vim.log.levels.ERROR, notes[1].level)
    end)

    it('falls back to the marked files when the ref is gone', function()
      stub(session, 'rev_parse', function(_, _, cb) cb(nil) end)
      stub(
        panel,
        'mark',
        function(_, file) return file.path == 'a.lua' and '⟳' or '✓' end
      )
      pickers.since()
      assert.matches('The ref of your last review is gone', said()[1])
      assert.equal(vim.log.levels.WARN, notes[1].level)
      assert.same({ { text = 'a.lua', path = 'a.lua' } }, picked[1].items)
    end)
  end)

  describe('pick', function()
    local origin = { name = 'origin', kind = 'github' }
    local lab = { name = 'lab', kind = 'gitlab' }
    local odd = { name = 'odd', kind = 'gitea' }

    it('says why it cannot review outside a repository', function()
      stub(session, 'repo_root', function(cb) cb(nil, 'not a git repo') end)
      pickers.pick()
      assert.same({ 'Cannot review here: not a git repo' }, said())
    end)

    it('says when no remote is on a known forge', function()
      stub(session, 'repo_root', function(cb) cb('/repo') end)
      stub(session, 'remotes', function(_, cb) cb({}) end)
      pickers.pick()
      assert.same({ 'No remote on a known forge' }, said())
    end)

    it('names the remotes it cannot review yet', function()
      stub(session, 'repo_root', function(cb) cb('/repo') end)
      stub(session, 'remotes', function(_, cb) cb({ odd }) end)
      stub(forge, 'for_remote', function() return nil, 'no adapter' end)
      pickers.pick()
      assert.same({
        'Not reviewed here yet: odd (no adapter)',
        'No open pull request',
      }, said())
    end)

    it('lists requested pull requests first, then newest', function()
      stub(session, 'repo_root', function(cb) cb('/repo') end)
      stub(session, 'remotes', function(_, cb) cb({ origin, lab, odd }) end)
      local adapters = {
        origin = {
          list = function(_, cb)
            cb({
              { id = '3', title = 'old', author = 'a' },
              { id = '9', title = 'new', author = 'b' },
            }, nil, true)
          end,
        },
        lab = {
          list = function(_, cb)
            cb({ { id = '1', title = 'asked', author = 'c', requested = true } })
          end,
        },
      }
      stub(forge, 'for_remote', function(remote)
        if adapters[remote.name] then return adapters[remote.name] end
        return nil, 'unknown'
      end)
      pickers.pick()
      assert.same({ 'origin: only the first pull requests' }, said())
      local opts = picked[1]
      assert.equal('Pull requests', opts.title)
      assert.same(
        { 'gitlab !1 asked c', 'github !9 new b', 'github !3 old a' },
        vim.tbl_map(function(item) return item.text end, opts.items)
      )
      assert.same({
        { 'GitLab       ', 'SnacksPickerComment' },
        { '!1     ', 'SnacksPickerLabel' },
        { 'asked ' },
        { 'c', 'SnacksPickerComment' },
        { '  review requested', 'DiagnosticWarn' },
      }, opts.format(opts.items[1]))
      assert.same(
        { 'gitea        ', 'SnacksPickerComment' },
        opts.format({
          remote = odd,
          pull = { id = '2', title = 't', author = 'x' },
        })[1]
      )
      assert.equal('', opts.format(opts.items[2])[5][1])

      local p = fake_picker()
      opts.confirm(p, opts.items[2])
      assert.is_true(p.closed)
      assert.same({ { origin, opts.items[2].pull } }, opened)
      opts.confirm(fake_picker(), nil)
      assert.equal(1, #opened)
    end)

    it('says a remote that failed to list, and that none is open', function()
      stub(session, 'repo_root', function(cb) cb('/repo') end)
      stub(session, 'remotes', function(_, cb) cb({ origin }) end)
      stub(forge, 'for_remote', function()
        return { list = function(_, cb) cb(nil, 'rate limited') end }
      end)
      pickers.pick()
      assert.same({ 'origin: rate limited', 'No open pull request' }, said())
      assert.same({}, picked)
    end)
  end)

  describe('branch', function()
    local origin = { name = 'origin', kind = 'github' }
    local fork = { name = 'fork', kind = 'github' }
    local pulls

    before_each(function()
      pulls = {}
      stub(session, 'start_dir', function() return '/repo' end)
      stub(session, 'repo_root', function(cb) cb('/repo') end)
      stub(session, 'remotes', function(_, cb) cb({ fork, origin }) end)
      stub(util_forge, 'branch', function(dir, cb)
        assert.equal('/repo', dir)
        cb('feature')
      end)
      stub(forge, 'for_remote', function()
        return {
          for_branch = function(remote, branch, cb)
            assert.equal('feature', branch)
            local pull = pulls[remote.name]
            if pull == 'error' then return cb(nil, 'down') end
            cb(pull)
          end,
        }
      end)
    end)

    it('says a detached HEAD has no branch to review', function()
      stub(util_forge, 'branch', function(_, cb) cb(nil) end)
      pickers.branch()
      assert.same({ 'Detached HEAD: no branch to review' }, said())
    end)

    it('opens the pull request on the remote the branch tracks', function()
      pulls.origin = { id = '5', title = 'mine' }
      pulls.fork = { id = '6', title = 'theirs' }
      stub(session, 'tracked_remote', function(dir, branch, cb)
        assert.same({ '/repo', 'feature' }, { dir, branch })
        cb('origin')
      end)
      pickers.branch()
      assert.same({ { origin, pulls.origin } }, opened)
      assert.same({}, selected)
    end)

    it('takes the first remote in forge order when none is tracked', function()
      pulls.origin = { id = '5', title = 'mine' }
      stub(session, 'tracked_remote', function(_, _, cb) cb(nil) end)
      pickers.branch()
      assert.same({ { origin, pulls.origin } }, opened)
    end)

    it('offers, never opens, a pull request of another remote', function()
      pulls.fork = { id = '6', title = 'theirs' }
      stub(session, 'tracked_remote', function(_, _, cb) cb('origin') end)
      selected.choose = true
      pickers.branch()
      local offer = selected[1]
      assert.equal('None on origin: review one of these?', offer.opts.prompt)
      assert.equal('fork !6 theirs', offer.opts.format_item(offer.items[1]))
      assert.same({ { fork, pulls.fork } }, opened)
    end)

    it('opens nothing when the offer is declined', function()
      pulls.fork = { id = '6', title = 'theirs' }
      stub(session, 'tracked_remote', function(_, _, cb) cb('origin') end)
      pickers.branch()
      assert.equal(1, #selected)
      assert.same({}, opened)
    end)

    it('says when no remote has a pull request for it', function()
      pulls.origin = 'error'
      stub(session, 'tracked_remote', function(_, _, cb) cb('origin') end)
      pickers.branch()
      assert.same({
        'origin: down',
        'No pull request for feature on origin',
      }, said())
    end)

    it('looks at every remote when none it tracks is a forge', function()
      stub(session, 'remotes', function(_, cb) cb({ fork }) end)
      stub(session, 'tracked_remote', function(_, _, cb) cb(nil) end)
      pickers.branch()
      assert.same(
        { 'No pull request for feature on a remote it tracks' },
        said()
      )
    end)
  end)
end)
