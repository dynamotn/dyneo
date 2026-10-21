local h = require('helpers')

describe('tools.review.drafts', function()
  local drafts

  before_each(function()
    h.unload('tools.review.drafts')
    drafts = require('tools.review.drafts')
  end)

  local function ai(fields)
    return vim.tbl_extend('force', {
      origin = 'ai',
      state = 'pending',
      path = 'a.lua',
      side = 'new',
      line = 1,
      body = 'ai says',
      severity = 'nit',
    }, fields or {})
  end

  local function user(fields)
    return vim.tbl_extend('force', {
      origin = 'user',
      state = 'ready',
      path = 'a.lua',
      side = 'new',
      line = 1,
      body = 'mine',
    }, fields or {})
  end

  describe('add', function()
    it('makes a ready user draft with a distinct id', function()
      local state = { reviewed = {}, drafts = {} }
      local a = drafts.add(
        state,
        { path = 'a.lua', side = 'new', line = 2, body = 'x' }
      )
      local b = drafts.add(
        state,
        { path = 'a.lua', side = 'new', line = 3, body = 'y' }
      )
      assert.equals('user', a.origin)
      assert.equals('ready', a.state)
      assert.equals(12, #a.id)
      assert.are_not.equals(a.id, b.id)
      assert.same({ a, b }, state.drafts)
    end)
  end)

  describe('set_state and set_body', function()
    it('changes the state of an AI draft', function()
      local d = ai()
      assert.is_true(drafts.set_state(d, 'kept'))
      assert.equals('kept', d.state)
    end)

    it('flips an AI draft to edited when its body changes', function()
      local d = ai()
      assert.is_true(drafts.set_body(d, 'mine'))
      assert.equals('mine', d.body)
      assert.equals('edited', d.state)
    end)

    it('leaves a user draft ready when its body changes', function()
      local d = user()
      assert.is_true(drafts.set_body(d, 'y'))
      assert.equals('ready', d.state)
      assert.equals('y', d.body)
    end)

    it('refuses to drop or edit a forge draft', function()
      local d = user({ origin = 'forge' })
      local ok, why = drafts.set_state(d, 'dropped')
      assert.is_false(ok)
      assert.is_string(why)
      ok, why = drafts.set_body(d, 'new')
      assert.is_false(ok)
      assert.is_string(why)
      assert.equals('ready', d.state)
      assert.equals('mine', d.body)
    end)
  end)

  describe('in_hunk', function()
    local hunks = { old = { { 10, 12 } }, new = { { 5, 8 }, { 20, 22 } } }

    it('checks each side on its own', function()
      assert.is_true(drafts.in_hunk(hunks, 'new', 6))
      assert.is_false(drafts.in_hunk(hunks, 'new', 10))
      assert.is_true(drafts.in_hunk(hunks, 'old', 10))
      assert.is_false(drafts.in_hunk(hunks, 'old', 6))
    end)

    it(
      'treats an empty side as outside',
      function()
        assert.is_false(drafts.in_hunk({ old = {}, new = {} }, 'old', 1))
      end
    )

    it('wants a whole range inside one hunk', function()
      assert.is_true(drafts.in_hunk(hunks, 'new', 8, 5))
      assert.is_false(drafts.in_hunk(hunks, 'new', 21, 8))
      assert.is_false(drafts.in_hunk(hunks, 'new', 9, 6))
    end)
  end)

  describe('set_state transitions', function()
    local function refused(d, to)
      local before = d.state
      local ok, why = drafts.set_state(d, to)
      assert.is_false(ok)
      assert.is_string(why)
      assert.equals(before, d.state)
    end

    it('lets an AI draft move among pending, kept and dropped', function()
      local d = ai()
      for _, to in ipairs({ 'kept', 'dropped', 'kept', 'pending', 'dropped' }) do
        assert.is_true(drafts.set_state(d, to))
        assert.equals(to, d.state)
      end
    end)

    it('reaches edited only through set_body', function()
      refused(ai(), 'edited')
      refused(ai({ state = 'edited' }), 'ready')
    end)

    it('allows a user draft only ready and dropped', function()
      refused(user(), 'pending')
      refused(user(), 'kept')
      refused(user(), 'edited')
      assert.is_true(drafts.set_state(user(), 'dropped'))
    end)

    it('allows a forge draft only ready', function()
      for _, to in ipairs({ 'pending', 'kept', 'edited', 'dropped' }) do
        refused(user({ origin = 'forge' }), to)
      end
      assert.is_true(drafts.set_state(user({ origin = 'forge' }), 'ready'))
    end)

    it('keeps an AI draft again after a drop', function()
      local d = ai()
      assert.is_true(drafts.set_state(d, 'dropped'))
      assert.is_true(drafts.set_state(d, 'kept'))
      assert.equals('kept', d.state)
    end)
  end)

  describe('replace_ai', function()
    it('drops pending AI drafts and keeps the rest', function()
      local state = {
        reviewed = {},
        drafts = {
          ai({ body = 'old' }),
          ai({ state = 'kept', body = 'k' }),
          user({ body = 'u' }),
          ai({ state = 'edited', body = 'e' }),
        },
      }
      drafts.replace_ai(state, { ai({ body = 'new' }) })
      local bodies = vim.tbl_map(function(d) return d.body end, state.drafts)
      assert.same({ 'k', 'u', 'e', 'new' }, bodies)
      assert.equals(12, #state.drafts[4].id)
    end)

    it('writes down the head new AI drafts were made on', function()
      local state = { reviewed = {}, drafts = {} }
      drafts.replace_ai(
        state,
        { ai({ body = 'new' }), ai({ body = 'kept', head = 'old' }) },
        'h2'
      )
      assert.equals('h2', state.drafts[1].head)
      assert.equals('old', state.drafts[2].head)
    end)
  end)

  describe('draw', function()
    local ns = vim.api.nvim_create_namespace('dy_review')
    local function marks(buf)
      return vim.api.nvim_buf_get_extmarks(buf, ns, 0, -1, { details = true })
    end

    it('marks a pending AI draft with the AI sign and group', function()
      local buf = h.buffer({ lines = { 'a', 'b', 'c' } })
      local state = { reviewed = {}, drafts = { ai({ line = 2 }) } }
      drafts.draw(buf, 'a.lua', 'new', state, {})
      local m = marks(buf)
      assert.equals(1, #m)
      assert.equals(1, m[1][2])
      local d = m[1][4]
      assert.truthy(d.sign_text:find(drafts.AI_SIGN, 1, true))
      assert.equals('DyReviewAiSign', d.sign_hl_group)
      assert.equals('DyReviewAiPending', d.virt_text[1][2])
      assert.truthy(d.virt_text[1][1]:find('AI nit: ai says', 1, true))
    end)

    it('draws each kind in its own group', function()
      local buf = h.buffer({ lines = { 'a', 'b', 'c', 'd' } })
      local state = {
        reviewed = {},
        drafts = {
          ai({ state = 'kept', line = 1 }),
          user({ line = 2, body = 'mine\nsecond' }),
          user({ origin = 'forge', line = 3, body = 'f' }),
          ai({ line = 4, side = 'old' }),
          ai({ line = 4, path = 'b.lua' }),
          ai({ line = 4, state = 'dropped' }),
        },
      }
      local threads = {
        {
          id = 't',
          path = 'a.lua',
          side = 'new',
          line = 4,
          resolved = false,
          comments = { { body = 'x' }, { body = 'y' } },
        },
        {
          id = 'u',
          path = 'z.lua',
          side = 'new',
          line = 1,
          resolved = false,
          comments = { { body = 'x' } },
        },
      }
      drafts.draw(buf, 'a.lua', 'new', state, threads)
      local m = marks(buf)
      assert.equals(4, #m)
      assert.equals('DyReviewAi', m[1][4].virt_text[1][2])
      assert.equals('DyReviewDraft', m[2][4].virt_text[1][2])
      assert.is_nil(m[2][4].virt_text[1][1]:find('second', 1, true))
      assert.truthy(m[3][4].virt_text[1][1]:find('pending on forge', 1, true))
      assert.equals('DyReviewThread', m[4][4].virt_text[1][2])
      assert.truthy(m[4][4].virt_text[1][1]:find('2', 1, true))
    end)

    it('says a draft carries a suggestion', function()
      local buf = h.buffer({ lines = { 'a', 'b' } })
      local state = {
        reviewed = {},
        drafts = {
          ai({ line = 1, suggestion = { 'x' } }),
          user({ line = 2, body = 'mine', suggestion = { 'y' } }),
        },
      }
      drafts.draw(buf, 'a.lua', 'new', state, {})
      local m = marks(buf)
      assert.truthy(m[1][4].virt_text[1][1]:find('+ suggestion', 1, true))
      assert.truthy(m[2][4].virt_text[1][1]:find('+ suggestion', 1, true))
    end)

    it('clears earlier marks and ignores an invalid buffer', function()
      local buf = h.buffer({ lines = { 'a' } })
      local state = { reviewed = {}, drafts = { ai() } }
      drafts.draw(buf, 'a.lua', 'new', state, {})
      drafts.draw(buf, 'a.lua', 'new', state, {})
      assert.equals(1, #marks(buf))
      vim.api.nvim_buf_delete(buf, { force = true })
      assert.has_no.errors(function()
        drafts.draw(buf, 'a.lua', 'new', state, {})
        drafts.draw(9999, 'a.lua', 'new', state, {})
      end)
    end)

    it('keeps a line past the end of the buffer on the last line', function()
      local buf = h.buffer({ lines = { 'a', 'b' } })
      local state = { reviewed = {}, drafts = { ai({ line = 50 }) } }
      drafts.draw(buf, 'a.lua', 'new', state, {})
      assert.equals(1, marks(buf)[1][2])
    end)
  end)

  it('defines default highlights', function()
    for _, name in pairs(drafts.HL) do
      assert.is_not_nil(vim.api.nvim_get_hl(0, { name = name }).link)
    end
  end)
end)
