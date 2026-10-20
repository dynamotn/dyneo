local h = require('helpers')

describe('tools.review.submit', function()
  local submit, session, store, git, diff, panel
  local s, notes, restore, sent, confirms, inputs, saves, refs

  local SECRET = 'SECRET-DRAFT-TEXT'
  local head = ('c'):rep(40)

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  --- Every message given, of any level
  local function said()
    return vim.tbl_map(function(note) return note.msg end, notes)
  end

  --- Whether a message given matches `pattern`
  local function told(pattern)
    for _, msg in ipairs(said()) do
      if msg:find(pattern, 1, true) then return true end
    end
    return false
  end

  local function draft(fields)
    return vim.tbl_extend('force', {
      origin = 'user',
      state = 'ready',
      path = 'src/a.lua',
      side = 'new',
      line = 2,
      body = SECRET,
    }, fields)
  end

  --- A fake adapter: each call to `submit` runs the next of `plays`
  ---@param plays fun(drafts: table[], review: table, progress: function, cb: function)[]
  local function adapter(plays)
    local calls = 0
    return {
      verdicts = {
        { id = 'approve', label = 'Approve' },
        { id = 'request_changes', label = 'Request changes' },
        { id = 'comment', label = 'Comment' },
      },
      get = function(_, _, cb) cb(vim.tbl_extend('force', s.pull, {})) end,
      submit = function(_, _, drafts, review, progress, cb)
        calls = calls + 1
        sent[#sent + 1] = {
          ids = vim.tbl_map(function(d) return d.id end, drafts),
          review = review,
        }
        local play = plays[calls] or function(_, _, _, done) done() end
        play(drafts, review, progress, cb)
      end,
    }
  end

  local function verdict(id)
    stub(vim.ui, 'select', function(items, _, cb)
      for _, item in ipairs(items) do
        if item.id == id then return cb(item) end
      end
      cb(nil)
    end)
  end

  --- Answers of `vim.ui.input`, one per call; nil once they run out
  local function answers(list)
    local i = 0
    stub(vim.ui, 'input', function(_, cb)
      i = i + 1
      inputs[#inputs + 1] = i
      cb(list[i])
    end)
  end

  --- Answers of `vim.fn.confirm`, one per call; Cancel once they run out
  local function confirm_with(list)
    local i = 0
    stub(vim.fn, 'confirm', function(msg)
      i = i + 1
      confirms[#confirms + 1] = msg
      return list[i] or 2
    end)
  end

  before_each(function()
    h.unload(
      'tools.review.submit',
      'tools.review.session',
      'tools.review.store',
      'tools.review.git',
      'tools.review.diff',
      'tools.review.panel',
      'tools.review.drafts'
    )
    session = require('tools.review.session')
    store = require('tools.review.store')
    git = require('tools.review.git')
    diff = require('tools.review.diff')
    panel = require('tools.review.panel')
    submit = require('tools.review.submit')
    notes, restore, sent, confirms, inputs, saves, refs =
      {}, {}, {}, {}, {}, {}, {}
    s = {
      remote = {
        name = 'origin',
        host = 'github.com',
        slug = 'o/r',
        kind = 'github',
      },
      forge = 'github',
      pull = { id = '7', title = 'feat: x', head_sha = head },
      root = '/repo',
      refs = 'refs/dyneo/review/github-7/',
      files = { { path = 'src/a.lua' } },
      hunks = { ['src/a.lua'] = { old = { { 1, 3 } }, new = { { 1, 5 } } } },
      threads = {},
      state = { reviewed = {}, drafts = {} },
      keyed = {},
    }
    s.adapter = adapter({})
    stub(session, 'current', function() return s end)
    stub(
      store,
      'save',
      function(_, _, state) saves[#saves + 1] = vim.deepcopy(state) end
    )
    stub(git, 'update_ref', function(_, ref, sha, cb)
      refs[#refs + 1] = { ref = ref, sha = sha }
      cb(true)
    end)
    stub(diff, 'redraw', function() end)
    stub(panel, 'refresh', function() end)
    stub(
      vim,
      'notify',
      function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    )
    verdict('comment')
    answers({ '' })
    confirm_with({ 1 })
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    assert.is_false(told(SECRET), 'a notification names draft text')
  end)

  it('sends what was confirmed and records the review', function()
    s.state.drafts = { draft({ id = 'a' }) }
    s.adapter = adapter({
      function(drafts, _, progress, cb)
        progress(drafts[1], 'F1')
        cb()
      end,
    })
    verdict('approve')
    submit.run(s)
    assert.same({ { ids = { 'a' }, review = { verdict = 'approve' } } }, sent)
    assert.equals('F1', s.state.drafts[1].posted)
    assert.equals('F1', saves[1].drafts[1].posted)
    assert.equals(head, s.state.last_head)
    assert.equals(head, saves[#saves].last_head)
    assert.same({ { ref = s.refs .. 'reviewed', sha = head } }, refs)
    assert.is_true(told('sent'))
  end)

  it('keeps posted drafts on a failure midway and sends no verdict', function()
    s.state.drafts = { draft({ id = 'a' }), draft({ id = 'b', line = 3 }) }
    s.adapter = adapter({
      function(drafts, _, progress, cb)
        progress(drafts[1], 'F1')
        cb('HTTP 502')
      end,
    })
    submit.run(s)
    assert.equals('F1', s.state.drafts[1].posted)
    assert.is_nil(s.state.drafts[2].posted)
    assert.equals('F1', saves[#saves].drafts[1].posted)
    assert.is_nil(s.state.last_head)
    assert.same({}, refs)
    assert.is_true(told('HTTP 502'))
    -- A resubmit sends only the unposted
    confirm_with({ 1 })
    answers({ '' })
    submit.run(s)
    assert.same({ 'b' }, sent[2].ids)
    assert.equals(head, s.state.last_head)
  end)

  it('never passes pending AI drafts and counts them', function()
    s.state.drafts = {
      draft({ id = 'a' }),
      draft({ id = 'p1', origin = 'ai', state = 'pending' }),
      draft({ id = 'p2', origin = 'ai', state = 'pending' }),
      draft({ id = 'k', origin = 'ai', state = 'kept' }),
      draft({ id = 'd', origin = 'ai', state = 'dropped' }),
    }
    submit.run(s)
    assert.same({ 'a', 'k' }, sent[1].ids)
    assert.matches('2 pending AI drafts', confirms[1])
  end)

  it('lists forge, pull request, verdict and counts', function()
    s.state.drafts = {
      draft({ id = 'a' }),
      draft({ id = 'r', reply_to = 'T1' }),
      draft({ id = 'x', reply_to = 'T2', body = '', resolve = true }),
      draft({ id = 'f', origin = 'forge', posted = nil }),
    }
    verdict('request_changes')
    submit.run(s)
    local text = confirms[1]
    assert.matches('GitHub', text)
    assert.matches('!7', text)
    assert.matches('Request changes', text)
    assert.matches('1 comment', text)
    assert.matches('1 repl', text)
    assert.matches('1 resolution', text)
    assert.matches('1 draft already pending on GitHub', text, 1, true)
    assert.is_nil(text:find(SECRET, 1, true))
  end)

  it('writes and sends nothing when the confirmation is cancelled', function()
    s.state.drafts = { draft({ id = 'a', line = 40 }) }
    confirm_with({ 2 })
    submit.run(s)
    assert.same({}, sent)
    assert.same({}, saves)
    assert.is_nil(s.state.drafts[1].file_level)
  end)

  it('refuses before any prompt when the head moved', function()
    s.state.drafts = { draft({ id = 'a' }) }
    s.adapter.get = function(_, _, cb)
      cb(vim.tbl_extend('force', s.pull, { head_sha = ('d'):rep(40) }))
    end
    submit.run(s)
    assert.same({}, sent)
    assert.same({}, confirms)
    assert.same({}, inputs)
    assert.is_true(
      told('The pull request moved to ddddddd: reopen it before submitting')
    )
  end)

  it('refuses a blocked review and a read-only pull request', function()
    s.state.drafts = { draft({ id = 'a' }) }
    s.blocked = 'pending review unreadable'
    submit.run(s)
    assert.is_true(told('pending review unreadable'))
    s.blocked = nil
    s.adapter.get = function(_, _, cb)
      cb(vim.tbl_extend('force', s.pull, { read_only = 'the PR is merged' }))
    end
    submit.run(s)
    assert.is_true(told('the PR is merged'))
    assert.same({}, sent)
    assert.same({}, confirms)
  end)

  it('refuses when the pull request cannot be read again', function()
    s.adapter.get = function(_, _, cb) cb(nil, 'gh: timeout') end
    submit.run(s)
    assert.is_true(told('gh: timeout'))
    assert.same({}, confirms)
  end)

  it('asks a request for changes with nothing to send for a body', function()
    s.state.drafts =
      { draft({ id = 'x', reply_to = 'T', body = '', resolve = true }) }
    verdict('request_changes')
    answers({ '', 'Please fix the tests' })
    submit.run(s)
    assert.equals(2, #inputs)
    assert.same(
      { verdict = 'request_changes', body = 'Please fix the tests' },
      sent[1].review
    )
  end)

  it('sends nothing when the body is refused and then cancelled', function()
    verdict('request_changes')
    answers({ '' })
    submit.run(s)
    assert.same({}, sent)
    assert.same({}, confirms)
  end)

  it('refuses a review with nothing to send', function()
    submit.run(s)
    assert.same({}, sent)
    assert.same({}, confirms)
    assert.is_true(told('Nothing to send'))
  end)

  it('sends lost drafts again once confirmed', function()
    s.state.drafts = {
      draft({ id = 'a', posted = 'OLD1' }),
      draft({ id = 'b', posted = 'OLD2', line = 3 }),
      draft({ id = 'c', posted = 'KEEP', line = 4 }),
    }
    s.adapter = adapter({
      function(_, _, _, cb)
        cb('2 drafts went into a deleted review', { lost = { 'a', 'b' } })
      end,
    })
    -- Send, send again, then confirm the second submit
    confirm_with({ 1, 1, 1 })
    answers({ 'body', 'body' })
    submit.run(s)
    assert.equals(2, #sent)
    assert.same({}, sent[1].ids)
    assert.same({ 'a', 'b' }, sent[2].ids)
    assert.equals('KEEP', s.state.drafts[3].posted)
    assert.matches('2 drafts', confirms[2])
  end)

  it('keeps lost drafts marked when sending again is declined', function()
    s.state.drafts = { draft({ id = 'a', posted = 'OLD1' }) }
    s.adapter = adapter({
      function(_, _, _, cb) cb('lost', { lost = { 'a' } }) end,
    })
    answers({ 'body' })
    confirm_with({ 1, 2 })
    submit.run(s)
    assert.equals(1, #sent)
    assert.equals('OLD1', s.state.drafts[1].posted)
  end)

  it('says when the review was already out or only resolved', function()
    s.adapter = adapter({
      function(_, _, _, cb) cb(nil, { already = 42 }) end,
      function(_, _, _, cb) cb(nil, { skipped = 'empty comment review' }) end,
    })
    answers({ 'body' })
    submit.run(s)
    assert.is_true(told('already'))
    s.state.drafts =
      { draft({ id = 'x', reply_to = 'T', body = '', resolve = true }) }
    answers({ '' })
    confirm_with({ 1 })
    submit.run(s)
    assert.is_true(told('Only the resolutions'))
  end)

  it('sends drafts outside the current diff as file comments', function()
    s.state.drafts = {
      draft({ id = 'in' }),
      draft({ id = 'out', line = 40 }),
      draft({ id = 'old', side = 'old', line = 9 }),
    }
    submit.run(s)
    assert.matches('2 drafts point outside the current diff', confirms[1])
    assert.matches('src/a.lua:40', confirms[1])
    assert.is_nil(s.state.drafts[1].file_level)
    assert.is_true(s.state.drafts[2].file_level)
    assert.is_true(s.state.drafts[3].file_level)
    assert.is_true(saves[1].drafts[2].file_level)
  end)

  it('reads hunks it lacks, and refuses when it cannot', function()
    s.state.drafts = { draft({ id = 'a', path = 'src/b.lua' }) }
    stub(session, 'load_hunks', function(sess, files, cb)
      assert.equals('src/b.lua', files[1].path)
      sess.hunks['src/b.lua'] = { old = {}, new = { { 1, 9 } } }
      cb()
    end)
    submit.run(s)
    assert.same({ 'a' }, sent[1].ids)
    s.state.drafts = { draft({ id = 'b', path = 'src/c.lua' }) }
    stub(session, 'load_hunks', function(_, _, cb) cb('git broke') end)
    confirm_with({ 1 })
    answers({ '' })
    submit.run(s)
    assert.equals(1, #sent)
    assert.is_true(told('git broke'))
  end)

  it('keeps the state in memory when it cannot be saved', function()
    s.state.drafts = { draft({ id = 'a' }) }
    stub(store, 'save', function() error('disk full') end)
    s.adapter = adapter({
      function(drafts, _, progress, cb)
        progress(drafts[1], 'F1')
        cb()
      end,
    })
    submit.run(s)
    assert.equals('F1', s.state.drafts[1].posted)
    assert.is_true(told('disk full'))
  end)

  it('is ready again after an adapter raises', function()
    s.state.drafts = { draft({ id = 'a' }) }
    s.adapter.submit = function() error('adapter bug') end
    submit.run(s)
    assert.is_true(told('adapter bug'))
    s.adapter = adapter({})
    confirm_with({ 1 })
    answers({ '' })
    submit.run(s)
    assert.equals(1, #sent)
    assert.is_false(told('already running'))
  end)

  it('runs one submit at a time', function()
    s.state.drafts = { draft({ id = 'a' }) }
    local finish
    s.adapter = adapter({
      function(_, _, _, cb) finish = cb end,
    })
    submit.run(s)
    submit.run(s)
    assert.equals(1, #sent)
    assert.is_true(told('already running'))
    finish()
    confirm_with({ 1 })
    answers({ '' })
    submit.run(s)
    assert.equals(2, #sent)
  end)
end)
