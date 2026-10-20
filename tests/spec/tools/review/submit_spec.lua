local h = require('helpers')

describe('tools.review.submit', function()
  local submit, session, store, git, diff, panel
  local s, notes, restore, sent, confirms, inputs, saves, refs, forge

  local SECRET = 'SECRET-DRAFT-TEXT'
  local head = ('c'):rep(40)

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  --- Whether a message given holds `text`
  local function told(text)
    for _, note in ipairs(notes) do
      if note.msg:find(text, 1, true) then return true end
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

  --- A forge keeping the adapter contract the way GitHub's adapter does
  ---
  --- Drafts are sent into one pending review, `posted` as
  --- `<review>/<comment>`; the verdict publishes it. The adapter is handed
  --- every draft but dropped and pending AI ones, posted ones included, and
  --- needs them: a posted draft into a review gone is `lost`, a pending
  --- comment no draft claims makes it refuse, and the review a posted draft
  --- went into tells a verdict that already went out.
  local function fake_forge()
    local f = {
      head = head,
      pending = nil, ---@type { id: integer, comments: integer[] }?
      published = {}, ---@type table<integer, { verdict: string, body?: string }>
      next = 100,
      fail_at = nil, ---@type integer? Fail before the n-th unposted draft
      verdict_times_out = false, -- publish, then answer with an error
    }
    local function id()
      f.next = f.next + 1
      return f.next
    end
    f.adapter = {
      verdicts = {
        { id = 'approve', label = 'Approve' },
        { id = 'request_changes', label = 'Request changes' },
        { id = 'comment', label = 'Comment' },
      },
      get = function(_, _, cb)
        cb(vim.tbl_extend('force', s.pull, { head_sha = f.head }))
      end,
      submit = function(_, _, drafts, review, progress, cb)
        sent[#sent + 1] = {
          ids = vim.tbl_map(function(d) return d.id end, drafts),
          review = review,
        }
        local lost, claimed, last, newest = {}, {}, nil, -1
        for _, d in ipairs(drafts) do
          assert.is_false(d.state == 'dropped', 'a dropped draft was passed')
          assert.is_false(
            d.origin == 'ai' and d.state == 'pending',
            'a pending AI draft was passed'
          )
          local r, c = tostring(d.posted):match('^(%d+)/(%d+)$')
          r, c = tonumber(r), tonumber(c)
          if c then
            claimed[c] = true
            if c > newest then
              last, newest = r, c
            end
            if not (f.pending and f.pending.id == r) and not f.published[r] then
              lost[#lost + 1] = d.id
            end
          end
        end
        if #lost > 0 then
          return cb(
            #lost .. ' drafts went into a deleted pending review',
            { lost = lost }
          )
        end
        for _, c in ipairs(f.pending and f.pending.comments or {}) do
          if not claimed[c] then
            return cb('the pending review no longer matches the drafts here')
          end
        end
        local unposted = vim.tbl_filter(
          function(d) return not d.posted end,
          drafts
        )
        local out = last and f.published[last]
        if
          #unposted == 0
          and out
          and out.verdict == review.verdict
          and (out.body or '') == (review.body or '')
        then
          return cb(nil, { already = last })
        end
        local words = vim.tbl_filter(
          function(d) return d.body ~= '' end,
          unposted
        )
        if #words == 0 and review.verdict == 'comment' and not review.body then
          for _, d in ipairs(unposted) do
            progress(d, 'resolved')
          end
          return cb(nil, { skipped = 'empty comment review' })
        end
        f.pending = f.pending or { id = id(), comments = {} }
        for i, d in ipairs(unposted) do
          if f.fail_at == i then
            f.fail_at = nil
            return cb('HTTP 502')
          end
          local c = id()
          table.insert(f.pending.comments, c)
          progress(d, ('%d/%d'):format(f.pending.id, c))
        end
        f.published[f.pending.id] =
          { verdict = review.verdict, body = review.body }
        f.pending = nil
        if f.verdict_times_out then
          f.verdict_times_out = false
          return cb('timed out')
        end
        cb()
      end,
    }
    return f
  end

  local function verdict(v)
    stub(vim.ui, 'select', function(items, _, cb)
      for _, item in ipairs(items) do
        if item.id == v then return cb(item) end
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

  --- Answers of `vim.fn.confirm`, one per call (a function is called and
  --- answers yes); Cancel once they run out
  local function confirm_with(list)
    local i = 0
    stub(vim.fn, 'confirm', function(msg)
      i = i + 1
      confirms[#confirms + 1] = msg
      local answer = list[i]
      if type(answer) == 'function' then
        answer()
        return 1
      end
      return answer or 2
    end)
  end

  --- Submit again, answering yes and an empty body
  local function again()
    confirm_with({ 1 })
    answers({ '' })
    submit.run(s)
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
    forge = fake_forge()
    s.adapter = forge.adapter
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
    verdict('approve')
    submit.run(s)
    assert.same({ { ids = { 'a' }, review = { verdict = 'approve' } } }, sent)
    assert.equals('101/102', s.state.drafts[1].posted)
    assert.equals('101/102', saves[1].drafts[1].posted)
    assert.same({ verdict = 'approve' }, forge.published[101])
    assert.equals(head, s.state.last_head)
    assert.equals(head, saves[#saves].last_head)
    assert.same({ { ref = s.refs .. 'reviewed', sha = head } }, refs)
    assert.is_true(told('Review sent'))
  end)

  it('resumes a submit cut short, sending only the rest', function()
    s.state.drafts = { draft({ id = 'a' }), draft({ id = 'b', line = 3 }) }
    forge.fail_at = 2
    submit.run(s)
    assert.equals('101/102', s.state.drafts[1].posted)
    assert.is_nil(s.state.drafts[2].posted)
    assert.equals('101/102', saves[#saves].drafts[1].posted)
    assert.same({}, forge.published)
    assert.is_nil(s.state.last_head)
    assert.same({}, refs)
    assert.is_true(told('HTTP 502'))
    again()
    -- The posted draft is handed over, so the forge knows its comment
    assert.same({ 'a', 'b' }, sent[2].ids)
    assert.equals('101/103', s.state.drafts[2].posted)
    assert.same({ verdict = 'comment' }, forge.published[101])
    assert.equals(head, s.state.last_head)
  end)

  it('does not send a verdict again after it timed out', function()
    s.state.drafts = { draft({ id = 'a' }) }
    verdict('approve')
    forge.verdict_times_out = true
    submit.run(s)
    assert.is_true(told('timed out'))
    assert.is_nil(s.state.last_head)
    again()
    assert.equals(1, vim.tbl_count(forge.published))
    assert.is_true(told('already out'))
    assert.equals(head, s.state.last_head)
  end)

  it('never passes dropped or pending AI drafts and counts these', function()
    s.state.drafts = {
      draft({ id = 'a' }),
      draft({ id = 'p1', origin = 'ai', state = 'pending' }),
      draft({ id = 'p2', origin = 'ai', state = 'pending' }),
      draft({ id = 'k', origin = 'ai', state = 'kept' }),
      draft({ id = 'd', origin = 'ai', state = 'dropped' }),
      draft({ id = 'u', state = 'dropped' }),
    }
    submit.run(s)
    assert.same({ 'a', 'k' }, sent[1].ids)
    assert.matches('2 pending AI drafts', confirms[1])
  end)

  it('counts only drafts not sent yet', function()
    forge.pending = { id = 50, comments = { 51 } }
    s.state.drafts = {
      draft({ id = 'old', posted = '50/51' }),
      draft({ id = 'a' }),
      draft({ id = 'r', reply_to = 'T1' }),
      draft({ id = 'x', reply_to = 'T2', body = '', resolve = true }),
      draft({ id = 'f', origin = 'forge' }),
    }
    verdict('request_changes')
    submit.run(s)
    local text = confirms[1]
    assert.matches('GitHub', text)
    assert.matches('!7', text)
    assert.matches('Request changes', text)
    assert.matches('1 comment,', text)
    assert.matches('1 reply', text)
    assert.matches('1 resolution', text)
    assert.matches('1 draft already pending on GitHub', text, 1, true)
    assert.is_nil(text:find(SECRET, 1, true))
    assert.same({ 'old', 'a', 'r', 'x', 'f' }, sent[1].ids)
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
    forge.head = ('d'):rep(40)
    submit.run(s)
    assert.same({}, sent)
    assert.same({}, confirms)
    assert.same({}, inputs)
    assert.is_true(
      told('The pull request moved to ddddddd: reopen it before submitting')
    )
  end)

  it('refuses when the head moved while confirming', function()
    s.state.drafts = { draft({ id = 'a' }) }
    confirm_with({ function() forge.head = ('e'):rep(40) end })
    submit.run(s)
    assert.same({}, sent)
    assert.same({}, saves)
    assert.is_true(told('moved to eeeeeee'))
  end)

  it('confirms again when a draft changed while asking', function()
    s.state.drafts = { draft({ id = 'a' }), draft({ id = 'b', line = 3 }) }
    confirm_with({
      function() s.state.drafts[2].body = 'other words' end,
      1,
    })
    submit.run(s)
    assert.equals(2, #confirms)
    assert.equals(1, #sent)
    assert.equals('other words', s.state.drafts[2].body)
    assert.is_truthy(s.state.drafts[2].posted)
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

  it('sends a plain approval with no draft and no body', function()
    verdict('approve')
    submit.run(s)
    assert.same({ { ids = {}, review = { verdict = 'approve' } } }, sent)
    assert.equals(1, vim.tbl_count(forge.published))
    assert.is_true(told('Review sent'))
  end)

  it('sends lost drafts again once confirmed', function()
    s.state.drafts = {
      draft({ id = 'a', posted = '5/6' }),
      draft({ id = 'b', posted = '5/7', line = 3 }),
      draft({ id = 'c', posted = '8/9', line = 4 }),
    }
    forge.published[8] = { verdict = 'comment' }
    -- Send, send again, then confirm the second submit
    confirm_with({ 1, 1, 1 })
    answers({ 'body', 'body' })
    submit.run(s)
    assert.is_true(told('2 drafts went into a deleted pending review'))
    assert.matches('2 drafts', confirms[2])
    assert.equals(2, #sent)
    assert.same({ 'a', 'b', 'c' }, sent[2].ids)
    assert.equals('8/9', s.state.drafts[3].posted)
    assert.matches('^101/', s.state.drafts[1].posted)
    assert.matches('^101/', s.state.drafts[2].posted)
  end)

  it('keeps lost drafts marked when sending again is declined', function()
    s.state.drafts = { draft({ id = 'a', posted = '5/6' }) }
    answers({ 'body' })
    confirm_with({ 1, 2 })
    submit.run(s)
    assert.equals(1, #sent)
    assert.equals('5/6', s.state.drafts[1].posted)
  end)

  it('says when only the resolutions were sent', function()
    s.state.drafts =
      { draft({ id = 'x', reply_to = 'T', body = '', resolve = true }) }
    submit.run(s)
    assert.is_true(told('Only the resolutions'))
    assert.equals('resolved', s.state.drafts[1].posted)
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
    again()
    assert.equals(1, #sent)
    assert.is_true(told('git broke'))
  end)

  it('keeps the state in memory when it cannot be saved', function()
    s.state.drafts = { draft({ id = 'a' }) }
    stub(store, 'save', function() error('disk full') end)
    submit.run(s)
    assert.equals('101/102', s.state.drafts[1].posted)
    assert.is_true(told('disk full'))
  end)

  describe('while a review is being sent', function()
    local finish

    before_each(function()
      s.state.drafts = { draft({ id = 'a' }) }
      s.adapter.submit = function(_, _, _, _, _, cb)
        sent[#sent + 1] = true
        finish = cb
      end
      submit.run(s)
      assert.is_true(submit.busy())
    end)

    it('runs no second submit', function()
      submit.run(s)
      assert.equals(1, #sent)
      assert.is_true(told('already running'))
      finish()
      assert.is_false(submit.busy())
      again()
      assert.equals(2, #sent)
    end)

    it('neither closes nor opens a review', function()
      local start = 0
      stub(session, 'start', function() start = start + 1 end)
      assert.is_false(session.close())
      session.open(s.remote, s.pull)
      assert.equals(0, start)
      assert.is_true(told('A review is being sent: wait for it to finish'))
      finish()
    end)
  end)

  it('is ready again after an adapter raises', function()
    s.state.drafts = { draft({ id = 'a' }) }
    s.adapter.submit = function() error('adapter bug') end
    submit.run(s)
    assert.is_true(told('adapter bug'))
    assert.is_false(submit.busy())
  end)
end)
