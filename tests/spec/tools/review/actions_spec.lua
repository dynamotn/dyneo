local h = require('helpers')

describe('tools.review.actions', function()
  local actions, session, diff, store, drafts
  local restore, notes, changed, s, live, located, bufnr

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  --- The messages given, `level` or above when it is given
  local function said(level)
    local out = {}
    for _, note in ipairs(notes) do
      if (note.level or 0) >= (level or 0) then out[#out + 1] = note.msg end
    end
    return out
  end

  --- A user draft on `line` of the new side of `src/a.lua`
  local function draft(fields)
    return vim.tbl_extend('force', {
      id = 'd1',
      origin = 'user',
      state = 'ready',
      path = 'src/a.lua',
      side = 'new',
      line = 3,
      body = 'hello',
    }, fields or {})
  end

  --- Write `lines` in the current float and save it with `:w`
  local function save(lines)
    local float = vim.api.nvim_get_current_win()
    assert.is_not.equal('', vim.api.nvim_win_get_config(float).relative)
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd('write')
    vim.wait(200, function() return not vim.api.nvim_win_is_valid(float) end)
    assert.is_false(vim.api.nvim_win_is_valid(float))
  end

  --- The lines of the float opened last, without saving it
  local function float_lines()
    local win = vim.api.nvim_get_current_win()
    assert.is_not.equal('', vim.api.nvim_win_get_config(win).relative)
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end

  before_each(function()
    h.unload(
      'tools.review.actions',
      'tools.review.session',
      'tools.review.diff',
      'tools.review.store',
      'tools.review.drafts'
    )
    session = require('tools.review.session')
    diff = require('tools.review.diff')
    store = require('tools.review.store')
    drafts = require('tools.review.drafts')
    actions = require('tools.review.actions')
    restore, notes, changed = {}, {}, {}

    bufnr = h.buffer({
      lines = { 'one', 'two', 'three', 'four', 'five', 'six' },
    })
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { 3, 0 })

    local a = { path = 'src/a.lua', blob = 'blob-a' }
    local b = { path = 'src/b.lua', blob = 'blob-b' }
    s = {
      remote = { host = 'example.com', owner = 'o', repo = 'r' },
      pull = { id = '7', head_sha = 'head1' },
      files = { a, b },
      buckets = { { kind = 'source', files = { a, b } } },
      hunks = { ['src/a.lua'] = { new = { { 2, 4 } }, old = { { 1, 2 } } } },
      threads = {},
      state = { drafts = {}, reviewed = {} },
    }
    live = s
    located = { 'src/a.lua', 'new' }

    stub(
      vim,
      'notify',
      function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
    )
    stub(session, 'need', function() return live end)
    stub(session, 'current', function() return live end)
    stub(
      session,
      'changed',
      function(x) changed[#changed + 1] = vim.deepcopy(x.state) end
    )
    stub(diff, 'locate', function(buf)
      if buf ~= bufnr then return nil end
      return located[1], located[2]
    end)
    stub(store, 'load', function() error('no store in this spec') end)
    stub(store, 'save', function() error('no store in this spec') end)
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_config(win).relative ~= '' then
        vim.api.nvim_win_close(win, true)
      end
    end
    vim.cmd('silent! %bwipeout!')
    h.unload('tools.review')
  end)

  describe('keys', function()
    local called

    before_each(function()
      called = {}
      for _, name in ipairs({ 'comment', 'ai_action', 'jump_ai', 'mark' }) do
        stub(
          actions,
          name,
          function(...) called[#called + 1] = { name, ... } end
        )
      end
      vim.g.maplocalleader = ','
      for _, key in ipairs(actions.keys()) do
        vim.keymap.set(key[1], key[2], key[3], { buffer = bufnr })
      end
    end)

    after_each(function() vim.g.maplocalleader = nil end)

    it('call the action each one names', function()
      vim.api.nvim_feedkeys(vim.keycode(',c,s,k,e,x]a[a'), 'x', false)
      assert.same({
        { 'comment' },
        { 'comment', { suggest = true } },
        { 'ai_action', 'keep' },
        { 'ai_action', 'edit' },
        { 'ai_action', 'drop' },
        { 'jump_ai', 1 },
        { 'jump_ai', -1 },
      }, called)
      vim.api.nvim_feedkeys(vim.keycode('V,c'), 'x', false)
      assert.same({ 'comment' }, called[8])
    end)

    it('mark the file of the current buffer only in the diff', function()
      vim.api.nvim_feedkeys(vim.keycode(',m'), 'x', false)
      assert.same({ 'mark', 'src/a.lua' }, called[1])
      located = {}
      vim.api.nvim_feedkeys(vim.keycode(',m'), 'x', false)
      assert.equal(1, #called)
    end)

    it('bind reply and resolve directly', function()
      local keys = {}
      for _, key in ipairs(actions.keys()) do
        keys[key[2]] = key[3]
      end
      assert.equal(actions.reply, keys['<localleader>r'])
      assert.equal(actions.toggle_resolve, keys['<localleader>R'])
    end)
  end)

  describe('comment', function()
    it('does nothing without a review', function()
      live = nil
      actions.comment()
      assert.equal(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('says when the buffer is not the diff', function()
      located = {}
      actions.comment()
      assert.same(
        { 'Not in the diff of the review' },
        said(vim.log.levels.WARN)
      )
      assert.equal(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('keeps a draft on the cursor line in the live review', function()
      actions.comment()
      local float_buf = vim.api.nvim_get_current_buf()
      assert.matches(
        '^dyreview://draft/%d+$',
        vim.api.nvim_buf_get_name(float_buf)
      )
      assert.equal('markdown', vim.bo[float_buf].filetype)
      assert.equal('acwrite', vim.bo[float_buf].buftype)
      assert.same({ '' }, float_lines())
      save({ 'Looks off', '' })
      assert.equal(1, #s.state.drafts)
      local d = s.state.drafts[1]
      assert.equal('Looks off', d.body)
      assert.is_nil(d.suggestion)
      assert.equal('src/a.lua', d.path)
      assert.equal('new', d.side)
      assert.equal(3, d.line)
      assert.is_nil(d.start_line)
      assert.equal('head1', d.head)
      assert.is_nil(d.file_level)
      assert.equal(1, #changed)
    end)

    it('saves nothing from an empty float', function()
      actions.comment()
      save({ '  ', '' })
      assert.same({}, s.state.drafts)
      assert.same({ 'Nothing written: no draft saved' }, said())
    end)

    it('takes the lines of a visual selection', function()
      vim.g.maplocalleader = ','
      for _, key in ipairs(actions.keys()) do
        vim.keymap.set(key[1], key[2], key[3], { buffer = bufnr })
      end
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      vim.api.nvim_feedkeys(vim.keycode('Vj,c'), 'x', false)
      vim.g.maplocalleader = nil
      save({ 'Two lines' })
      local d = s.state.drafts[1]
      assert.equal(2, d.start_line)
      assert.equal(3, d.line)
      assert.equal('n', vim.fn.mode())
    end)

    it('keeps one line when the selection has one', function()
      vim.g.maplocalleader = ','
      for _, key in ipairs(actions.keys()) do
        vim.keymap.set(key[1], key[2], key[3], { buffer = bufnr })
      end
      vim.api.nvim_feedkeys(vim.keycode('V,c'), 'x', false)
      vim.g.maplocalleader = nil
      save({ 'One line' })
      assert.is_nil(s.state.drafts[1].start_line)
      assert.equal(3, s.state.drafts[1].line)
    end)

    it('sends a line outside the diff as a file comment', function()
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      actions.comment()
      assert.same(
        { 'Outside the diff: sent as a file comment naming line 6' },
        said(vim.log.levels.WARN)
      )
      save({ 'Far away' })
      assert.is_true(s.state.drafts[1].file_level)
    end)

    it('starts a suggestion from the lines of the new side', function()
      actions.comment({ suggest = true })
      assert.same({ '', '```suggestion', 'three', '```' }, float_lines())
      save({
        'Rename it',
        '````suggestion',
        'trois',
        '```',
        'still the suggestion',
        '````',
        'after',
      })
      local d = s.state.drafts[1]
      assert.equal('Rename it\nafter', d.body)
      assert.same({ 'trois', '```', 'still the suggestion' }, d.suggestion)
    end)

    it('refuses a suggestion on the old side', function()
      located = { 'src/a.lua', 'old' }
      actions.comment({ suggest = true })
      assert.same(
        { 'A suggestion replaces lines of the new side' },
        said(vim.log.levels.WARN)
      )
      assert.equal(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('reads the hunks of a file left out', function()
      located = { 'src/b.lua', 'new' }
      local asked
      stub(session, 'load_hunks', function(x, files, cb)
        asked = files
        x.hunks['src/b.lua'] = { new = { { 1, 9 } }, old = {} }
        cb()
      end)
      actions.comment()
      assert.equal(s.files[2], asked[1])
      save({ 'On b' })
      assert.equal('src/b.lua', s.state.drafts[1].path)
      assert.is_nil(s.state.drafts[1].file_level)
    end)

    it('names a file not in the review by its path', function()
      located = { 'src/gone.lua', 'new' }
      local asked
      stub(session, 'load_hunks', function(_, files, cb)
        asked = files
        cb('git failed')
      end)
      actions.comment()
      assert.same({ { path = 'src/gone.lua' } }, asked)
      assert.same(
        { 'Could not read the diff of src/gone.lua: git failed' },
        said(vim.log.levels.ERROR)
      )
      assert.equal(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('says a failed read without a reason', function()
      located = { 'src/b.lua', 'new' }
      stub(session, 'load_hunks', function(_, _, cb) cb() end)
      actions.comment()
      assert.same(
        { 'Could not read the diff of src/b.lua: ?' },
        said(vim.log.levels.ERROR)
      )
    end)
  end)

  describe('a float saved after its review closed', function()
    it('changes the review open on the pull request now', function()
      actions.comment()
      local other = vim.deepcopy(s)
      other.state = { drafts = {}, reviewed = {} }
      live = other
      save({ 'Late' })
      assert.same({}, s.state.drafts)
      assert.equal('Late', other.state.drafts[1].body)
      assert.equal(1, #changed)
    end)

    it('changes the state on disk with no review open', function()
      actions.comment()
      live = nil
      local disk = { drafts = {}, reviewed = {} }
      local saved
      stub(store, 'load', function(remote, id)
        assert.equal(s.remote, remote)
        assert.equal('7', id)
        return disk
      end)
      stub(store, 'save', function(_, _, state) saved = state end)
      save({ 'Late' })
      assert.equal(disk, saved)
      assert.equal('Late', disk.drafts[1].body)
      assert.same({ 'Kept in the closed review of !7' }, said())
      assert.same({}, changed)
    end)

    it('changes the state on disk when another review is open', function()
      actions.comment()
      live = vim.tbl_extend('force', s, { pull = { id = '8' } })
      local saved
      stub(store, 'load', function() return { drafts = {}, reviewed = {} } end)
      stub(store, 'save', function(_, _, state) saved = state end)
      save({ 'Late' })
      assert.equal('Late', saved.drafts[1].body)
    end)

    it('says when the state cannot be read', function()
      actions.comment()
      live = nil
      save({ 'Late' })
      local errors = said(vim.log.levels.ERROR)
      assert.equal(1, #errors)
      assert.matches(
        '^Could not read the review: .*no store in this spec',
        errors[1]
      )
    end)

    it('says when the state cannot be saved', function()
      actions.comment()
      live = nil
      stub(store, 'load', function() return { drafts = {}, reviewed = {} } end)
      save({ 'Late' })
      local errors = said(vim.log.levels.ERROR)
      assert.equal(1, #errors)
      assert.matches(
        '^Could not save the review: .*no store in this spec',
        errors[1]
      )
      assert.is_false(
        vim.tbl_contains(said(), 'Kept in the closed review of !7')
      )
    end)
  end)

  describe('reply', function()
    before_each(
      function()
        s.threads = {
          { id = 't0', path = 'src/b.lua', side = 'new', line = 3 },
          { id = 't1', path = 'src/a.lua', side = 'old', line = 3 },
          { id = 't2', path = 'src/a.lua', side = 'new' },
          {
            id = 't3',
            path = 'src/a.lua',
            side = 'new',
            line = 5,
            start_line = 2,
          },
        }
      end
    )

    it('does nothing without a review', function()
      live = nil
      actions.reply()
      assert.equal(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('says when no thread is on the line', function()
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      actions.reply()
      assert.same({ 'No thread on this line' }, said(vim.log.levels.WARN))
    end)

    it('keeps a reply to the thread spanning the line', function()
      actions.reply()
      assert.same({ '' }, float_lines())
      save({ 'Agreed', '```suggestion', 'x', '```' })
      local d = s.state.drafts[1]
      assert.equal('Agreed', d.body)
      assert.is_nil(d.suggestion)
      assert.equal('t3', d.reply_to)
      assert.equal(5, d.line)
      assert.equal('head1', d.head)
      assert.equal('user', d.origin)
    end)
  end)

  describe('toggle_resolve', function()
    before_each(
      function()
        s.threads =
          { { id = 't1', path = 'src/a.lua', side = 'new', line = 3 } }
      end
    )

    it('does nothing without a review', function()
      live = nil
      actions.toggle_resolve()
      assert.same({}, changed)
    end)

    it('says when no thread is on the line', function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      actions.toggle_resolve()
      assert.same({ 'No thread on this line' }, said(vim.log.levels.WARN))
    end)

    it('adds an empty resolving reply, then takes it back', function()
      actions.toggle_resolve()
      local d = s.state.drafts[1]
      assert.equal('', d.body)
      assert.is_true(d.resolve)
      assert.equal('t1', d.reply_to)
      assert.equal('head1', d.head)
      assert.same({ 'Resolves with the review' }, said())
      actions.toggle_resolve()
      assert.same({}, s.state.drafts)
      assert.same({ 'Resolves with the review', 'Left open' }, said())
      assert.equal(2, #changed)
    end)

    it('carries the resolve on a written reply', function()
      s.state.drafts = {
        draft({ id = 'x1', reply_to = 't1', state = 'dropped' }),
        draft({ id = 'x2', reply_to = 't1', posted = true }),
        draft({ id = 'x3', reply_to = 't1', origin = 'ai' }),
        draft({ id = 'x4', reply_to = 't1', body = 'Fixed' }),
      }
      actions.toggle_resolve()
      assert.is_true(s.state.drafts[4].resolve)
      actions.toggle_resolve()
      assert.is_false(s.state.drafts[4].resolve)
      assert.equal(4, #s.state.drafts)
      assert.is_nil(s.state.drafts[1].resolve)
    end)

    it('says a resolved thread is resolved already', function()
      s.threads[1].resolved = true
      actions.toggle_resolve()
      assert.same({ 'The thread is resolved already' }, said())
      assert.same({}, s.state.drafts)
      assert.same({}, changed)
    end)
  end)

  describe('ai_action', function()
    it('does nothing without a review', function()
      live = nil
      actions.ai_action('keep')
      assert.same({}, changed)
    end)

    it('says when no draft is on the line', function()
      s.state.drafts = {
        draft({ path = 'src/b.lua' }),
        draft({ side = 'old' }),
        draft({ posted = true }),
        draft({ state = 'dropped' }),
        draft({ line = 2 }),
        draft({ line = 5, start_line = 4 }),
      }
      actions.ai_action('drop')
      assert.same({ 'No draft on this line' }, said(vim.log.levels.WARN))
    end)

    it('acts on the AI draft first among those on the line', function()
      s.state.drafts = {
        draft({ id = 'u1' }),
        draft({
          id = 'a1',
          origin = 'ai',
          state = 'pending',
          line = 4,
          start_line = 2,
        }),
        draft({ id = 'u2' }),
      }
      actions.ai_action('keep')
      assert.equal('kept', s.state.drafts[2].state)
      assert.equal('ready', s.state.drafts[1].state)
      assert.equal(1, #changed)
      actions.ai_action('drop')
      assert.equal('dropped', s.state.drafts[2].state)
    end)

    it('says why a draft cannot change', function()
      s.state.drafts = { draft() }
      actions.ai_action('keep')
      assert.same(
        { 'a user draft cannot become kept' },
        said(vim.log.levels.WARN)
      )
      assert.same({}, changed)
    end)

    it('refuses to edit a draft pending on the forge', function()
      s.state.drafts = { draft({ origin = 'forge' }) }
      actions.ai_action('edit')
      assert.same(
        { 'A draft pending on the forge cannot be edited here' },
        said(vim.log.levels.WARN)
      )
      assert.equal(bufnr, vim.api.nvim_get_current_buf())
    end)

    it('edits the body and the suggestion it shows', function()
      s.state.drafts = {
        draft({ origin = 'ai', state = 'pending', suggestion = { 'a ``` b' } }),
      }
      actions.ai_action('edit')
      assert.same(
        { 'hello', '', '````suggestion', 'a ``` b', '````' },
        float_lines()
      )
      save({ 'better' })
      local d = s.state.drafts[1]
      assert.equal('better', d.body)
      assert.equal('edited', d.state)
      assert.is_nil(d.suggestion)
      assert.equal(1, #changed)
    end)

    it('shows a suggestion alone when the body is empty', function()
      s.state.drafts = { draft({ body = '', suggestion = { 'x' } }) }
      actions.ai_action('edit')
      assert.same({ '```suggestion', 'x', '```' }, float_lines())
      save({ '```suggestion', 'y', '```' })
      assert.equal('', s.state.drafts[1].body)
      assert.same({ 'y' }, s.state.drafts[1].suggestion)
    end)

    it('shows the body alone without a suggestion', function()
      s.state.drafts = { draft({ body = 'a\nb' }) }
      actions.ai_action('edit')
      assert.same({ 'a', 'b' }, float_lines())
    end)

    it('says the edit is lost when the draft is gone', function()
      s.state.drafts = { draft() }
      actions.ai_action('edit')
      s.state.drafts = {}
      save({ 'too late' })
      assert.same(
        { 'The draft is gone: the edit is not kept' },
        said(vim.log.levels.WARN)
      )
    end)

    it('says why the saved draft cannot be edited', function()
      s.state.drafts = { draft() }
      actions.ai_action('edit')
      live = nil
      local saved
      stub(
        store,
        'load',
        function()
          return { drafts = { draft({ origin = 'forge' }) }, reviewed = {} }
        end
      )
      stub(store, 'save', function(_, _, state) saved = state end)
      save({ 'too late' })
      assert.same(
        { 'a draft pending on the forge cannot be edited here' },
        said(vim.log.levels.WARN)
      )
      assert.equal('hello', saved.drafts[1].body)
    end)
  end)

  describe('jump_ai', function()
    local shown

    local function ai(path, line, fields)
      return draft(vim.tbl_extend('force', {
        id = path .. line,
        origin = 'ai',
        state = 'pending',
        path = path,
        line = line,
      }, fields or {}))
    end

    before_each(function()
      shown = {}
      package.loaded['tools.review'] = {
        show = function(path) shown[#shown + 1] = path end,
      }
      s.state.drafts = {
        ai('src/b.lua', 2),
        ai('src/a.lua', 5),
        ai('src/a.lua', 1),
        ai('src/a.lua', 4, { state = 'kept' }),
        ai('src/a.lua', 6, { origin = 'user' }),
        ai('src/x.lua', 1),
        ai('src/a.lua', 6, { side = 'old' }),
      }
    end)

    it('does nothing without a review', function()
      live = nil
      actions.jump_ai(1)
      assert.same({}, shown)
    end)

    it('moves to the next pending AI draft in this file', function()
      actions.jump_ai(1)
      assert.same({ 5, 0 }, vim.api.nvim_win_get_cursor(0))
      assert.same({}, shown)
    end)

    it('moves back to the previous one in this file', function()
      actions.jump_ai(-1)
      assert.same({ 1, 0 }, vim.api.nvim_win_get_cursor(0))
    end)

    it('opens the next file that has one', function()
      vim.api.nvim_win_set_cursor(0, { 6, 0 })
      actions.jump_ai(1)
      assert.same({ 'src/b.lua' }, shown)
      assert.same({ path = 'src/b.lua', side = 'new', line = 2 }, s.jump)
    end)

    it('opens the other side of this file', function()
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      located = { 'src/a.lua', 'old' }
      actions.jump_ai(1)
      assert.same({ 'src/a.lua' }, shown)
      assert.same({ path = 'src/a.lua', side = 'new', line = 5 }, s.jump)
    end)

    it('reaches a file outside the review last', function()
      located = { 'src/b.lua', 'new' }
      vim.api.nvim_win_set_cursor(0, { 2, 0 })
      actions.jump_ai(1)
      assert.same({ 'src/x.lua' }, shown)
    end)

    it('says when there is none that way', function()
      located = {}
      s.state.drafts = { ai('src/a.lua', 1) }
      actions.jump_ai(-1)
      assert.same({ 'No pending AI draft that way' }, said())
      assert.same({}, shown)
    end)
  end)

  describe('mark', function()
    it('does nothing without a review', function()
      live = nil
      actions.mark('src/a.lua')
      assert.same({}, changed)
    end)

    it('ignores a file not in the review', function()
      actions.mark('src/gone.lua')
      assert.same({}, changed)
    end)

    it('marks a file at its blob, then takes the mark back', function()
      actions.mark('src/a.lua')
      assert.equal('blob-a', s.state.reviewed['src/a.lua'])
      actions.mark('src/a.lua')
      assert.is_nil(s.state.reviewed['src/a.lua'])
      assert.equal(2, #changed)
    end)

    it('marks again a file reviewed at an older blob', function()
      s.state.reviewed['src/a.lua'] = 'old'
      actions.mark('src/a.lua')
      assert.equal('blob-a', s.state.reviewed['src/a.lua'])
    end)

    it('marks a file without a blob', function()
      s.files[1].blob = nil
      actions.mark('src/a.lua')
      assert.equal('', s.state.reviewed['src/a.lua'])
    end)
  end)
end)
