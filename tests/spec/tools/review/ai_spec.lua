local h = require('helpers')

describe('tools.review.ai', function()
  local ai, restore

  local function stub(tbl, key, value)
    restore[#restore + 1] = h.stub(tbl, key, value)
  end

  local function file(path, fields)
    return vim.tbl_extend('force', {
      path = path,
      status = 'M',
      kind = 'source',
      added = 1,
      removed = 1,
      risk = 0,
      binary = false,
    }, fields or {})
  end

  before_each(function()
    h.unload(
      'tools.review.ai',
      'tools.review.git',
      'tools.review.session',
      'tools.review.drafts',
      'tools.review.triage',
      'tools.ai',
      'tools.ai.git'
    )
    ai = require('tools.review.ai')
    restore = {}
  end)

  after_each(function()
    for i = #restore, 1, -1 do
      restore[i]()
    end
  end)

  describe('chunks', function()
    it('splits the diff by file to fit the budget, in file order', function()
      local files = { file('a.lua'), file('b.lua'), file('c.lua') }
      local diffs = {
        ['a.lua'] = ('a'):rep(39) .. '\n',
        ['b.lua'] = ('b'):rep(39) .. '\n',
        ['c.lua'] = ('c'):rep(39) .. '\n',
      }
      local chunks, left = ai.chunks(files, diffs, 100)
      assert.equals(2, #chunks)
      assert.same({ 'a.lua', 'b.lua' }, chunks[1].paths)
      assert.equals(diffs['a.lua'] .. diffs['b.lua'], chunks[1].text)
      assert.same({ 'c.lua' }, chunks[2].paths)
      assert.is_falsy(chunks[1].cut)
      assert.same({}, left)
    end)

    it('leaves out generated and binary files, and names them', function()
      local files = {
        file('go.sum', { kind = 'generated' }),
        file('src/a.lua'),
        file('logo.png', { binary = true }),
        file('huge.lua'),
      }
      local chunks, left = ai.chunks(files, { ['src/a.lua'] = 'diff\n' }, 100)
      assert.equals(1, #chunks)
      assert.same({ 'src/a.lua' }, chunks[1].paths)
      assert.same({
        { path = 'go.sum', why = 'generated' },
        { path = 'logo.png', why = 'binary' },
        { path = 'huge.lua', why = 'too large' },
      }, left)
    end)

    it('gives one oversized file a chunk of its own, cut and said', function()
      local files = { file('a.lua'), file('big.lua'), file('c.lua') }
      local big = {}
      for i = 1, 20 do
        big[i] = ('+line %02d'):format(i)
      end
      local diffs = {
        ['a.lua'] = 'small a\n',
        ['big.lua'] = table.concat(big, '\n') .. '\n',
        ['c.lua'] = 'small c\n',
      }
      local chunks = ai.chunks(files, diffs, 50)
      assert.equals(3, #chunks)
      assert.same({ 'big.lua' }, chunks[2].paths)
      assert.is_true(chunks[2].cut)
      assert.is_truthy(chunks[2].text:find('+line 01', 1, true))
      assert.is_falsy(chunks[2].text:find('+line 20', 1, true))
      assert.is_truthy(chunks[2].text:find('big.lua cut at', 1, true))
      assert.same({ 'c.lua' }, chunks[3].paths)
    end)

    it('carries the old path of a renamed file', function()
      local files = { file('new.lua', { status = 'R', old_path = 'old.lua' }) }
      local chunks = ai.chunks(files, { ['new.lua'] = 'd\n' }, 100)
      assert.same({ 'old.lua' }, chunks[1].old_paths)
      assert.same({ ['old.lua'] = 'new.lua' }, chunks[1].renamed)
    end)

    it('says the last line of each side sent of a cut file', function()
      local lines = { '@@ -1,1 +1,20 @@', ' ctx' }
      for i = 2, 20 do
        lines[#lines + 1] = ('+line %02d'):format(i)
      end
      local diffs = { ['big.lua'] = table.concat(lines, '\n') .. '\n' }
      local chunks = ai.chunks({ file('big.lua') }, diffs, 50)
      assert.is_true(chunks[1].cut)
      assert.same({ old = 1, new = 4 }, chunks[1].last['big.lua'])
    end)
  end)

  describe('parse', function()
    local hunks = {
      ['src/a.lua'] = { new = { { 10, 20 } }, old = { { 5, 6 } } },
      ['src/b.lua'] = { new = { { 1, 3 } }, old = {} },
    }

    it('reads the first JSON object out of prose', function()
      local answer = table.concat({
        'Here is the review {as asked}:',
        '```json',
        vim.json.encode({
          summary = 'Adds a thing } with braces {',
          order = { 'src/b.lua', 'src/a.lua' },
          comments = {
            {
              path = 'src/a.lua',
              side = 'new',
              line = 12,
              severity = 'blocker',
              body = 'Leaks the handle',
            },
            {
              path = 'src/a.lua',
              side = 'old',
              line = 6,
              start_line = 5,
              severity = 'nit',
              body = 'Old name',
            },
          },
        }),
        '```',
        'Anything else? {',
      }, '\n')
      local result, err = ai.parse(answer, hunks)
      assert.is_nil(err)
      assert.equals('Adds a thing } with braces {', result.summary)
      assert.same({ 'src/b.lua', 'src/a.lua' }, result.order)
      assert.equals(0, result.outside)
      assert.equals(2, #result.drafts)
      assert.same({
        path = 'src/a.lua',
        side = 'new',
        line = 12,
        severity = 'blocker',
        body = 'Leaks the handle',
      }, result.drafts[1])
      assert.equals(5, result.drafts[2].start_line)
      assert.equals('old', result.drafts[2].side)
    end)

    it('says when the answer holds no JSON that reads', function()
      local result, err = ai.parse('{"summary": "x", comments: [}', hunks)
      assert.is_nil(result)
      assert.is_truthy(err)
      assert.is_nil((ai.parse('no json here', hunks)))
    end)

    it('counts and drops comments outside the diff', function()
      local result = ai.parse(
        vim.json.encode({
          comments = {
            { path = 'src/a.lua', line = 30, body = 'beyond the hunk' },
            { path = 'src/zzz.lua', line = 1, body = 'not in the diff' },
            { path = 'src/b.lua', line = 2, body = 'inside' },
            { path = 'src/a.lua', line = 19, start_line = 9, body = 'across' },
          },
        }),
        hunks
      )
      assert.equals(3, result.outside)
      assert.equals(1, #result.drafts)
      assert.equals('src/b.lua', result.drafts[1].path)
      assert.equals('new', result.drafts[1].side)
    end)

    it('takes an unknown or missing severity as a suggestion', function()
      local result = ai.parse(
        vim.json.encode({
          comments = {
            { path = 'src/b.lua', line = 1, severity = 'critical', body = 'x' },
            { path = 'src/b.lua', line = 2, body = 'y' },
            { path = 'src/b.lua', line = 3, severity = 'question', body = 'z' },
          },
        }),
        hunks
      )
      assert.same(
        { 'suggestion', 'suggestion', 'question' },
        vim.tbl_map(function(d) return d.severity end, result.drafts)
      )
    end)

    it('normalizes the paths of comments and of the order', function()
      local result = ai.parse(
        vim.json.encode({
          order = { './src/a.lua', 'src\\b.lua' },
          comments = {
            { path = './src/a.lua', line = 10, body = 'x' },
            { path = 'src\\b.lua', line = 1, body = 'y' },
            { path = 'b/src/a.lua', line = 11, body = 'z' },
          },
        }),
        hunks
      )
      assert.same({ 'src/a.lua', 'src/b.lua' }, result.order)
      assert.same(
        { 'src/a.lua', 'src/b.lua', 'src/a.lua' },
        vim.tbl_map(function(d) return d.path end, result.drafts)
      )
      assert.equals(0, result.outside)
    end)

    it('maps the old path of a renamed file to its new one', function()
      local result = ai.parse(
        vim.json.encode({
          comments = {
            { path = 'src/old_a.lua', side = 'old', line = 5, body = 'x' },
          },
        }),
        hunks,
        { renamed = { ['src/old_a.lua'] = 'src/a.lua' } }
      )
      assert.equals(0, result.outside)
      assert.equals('src/a.lua', result.drafts[1].path)
      assert.equals('old', result.drafts[1].side)
    end)

    it('keeps a suggestion as lines, on the new side only', function()
      local result = ai.parse(
        vim.json.encode({
          comments = {
            {
              path = 'src/a.lua',
              line = 11,
              body = 'Use local',
              suggestion = 'local x = 1\nlocal y = 2',
            },
            {
              path = 'src/a.lua',
              side = 'old',
              line = 5,
              body = 'Was',
              suggestion = 'nope',
            },
            { path = 'src/a.lua', line = 12, body = '   ' },
          },
        }),
        hunks
      )
      assert.equals(2, #result.drafts)
      assert.same({ 'local x = 1', 'local y = 2' }, result.drafts[1].suggestion)
      assert.is_nil(result.drafts[2].suggestion)
    end)
  end)

  describe('run', function()
    local s, notes, sent, changed, answers, failing, session_mod

    --- What the AI answers for a chunk holding `paths`
    local function answer_for(paths)
      local comments = {}
      for _, path in ipairs(paths) do
        comments[#comments + 1] = {
          path = path,
          side = 'new',
          line = 2,
          severity = 'blocker',
          body = 'ANSWERTEXT about ' .. path,
        }
      end
      return 'Sure: '
        .. vim.json.encode({
          summary = 'SUMMARYTEXT of ' .. table.concat(paths, ' '),
          order = vim.fn.reverse(vim.deepcopy(paths)),
          comments = comments,
        })
    end

    local function draft(fields)
      return vim.tbl_extend('force', {
        id = fields.id,
        path = 'src/a.lua',
        side = 'new',
        line = 1,
        body = 'old',
      }, fields)
    end

    before_each(function()
      notes, sent, changed, failing, answers = {}, {}, 0, {}, nil
      local triage = require('tools.review.triage')
      local files = {
        file('src/a.lua'),
        file('src/b.lua', { status = 'R', old_path = 'src/old_b.lua' }),
        file('go.sum', { kind = 'generated' }),
      }
      s = {
        root = '/repo',
        merge_base = 'base',
        pull = {
          id = '7',
          title = 'feat: x',
          body = 'Body of the PR',
          head_sha = 'head',
        },
        files = files,
        buckets = triage.buckets(files),
        hunks = {},
        threads = {},
        state = {
          reviewed = {},
          drafts = {
            draft({ id = 'p-a', origin = 'ai', state = 'pending' }),
            draft({
              id = 'p-b',
              origin = 'ai',
              state = 'pending',
              path = 'src/b.lua',
            }),
            draft({ id = 'k', origin = 'ai', state = 'kept' }),
            draft({ id = 'e', origin = 'ai', state = 'edited' }),
            draft({ id = 'u', origin = 'user', state = 'ready' }),
          },
        },
      }
      session_mod = require('tools.review.session')
      stub(session_mod, 'current', function() return s end)
      stub(session_mod, 'changed', function() changed = changed + 1 end)
      local git = require('tools.review.git')
      stub(git, 'diff', function(_, base, head, paths, _, cb)
        assert.equals('base', base)
        assert.equals('head', head)
        local diffs = {}
        for _, entry in ipairs(paths) do
          local path = type(entry) == 'table' and entry.path or entry
          diffs[path] = ('DIFFTEXT of %s\n'):format(path)
        end
        cb(diffs, nil, false)
      end)
      stub(
        git,
        'hunks',
        function(_, _, _, _, _, cb) cb({ new = { { 1, 5 } }, old = {} }) end
      )
      local headless = require('tools.ai')
      stub(headless, 'headless', function(text, root, label, on_done, opts)
        sent[#sent + 1] =
          { text = text, root = root, label = label, paths = opts.paths }
        local paths = {}
        for _, path in ipairs(opts.paths) do
          if path:match('^src/[ab]%.lua$') then paths[#paths + 1] = path end
        end
        if failing[paths[1]] then return opts.on_fail('it failed') end
        on_done(answers and answers(paths) or answer_for(paths))
      end)
      stub(
        vim,
        'notify',
        function(msg, level) notes[#notes + 1] = { msg = msg, level = level } end
      )
    end)

    it('replaces only the pending AI drafts', function()
      ai.run(s)
      assert.equals(1, #sent)
      assert.equals(1, changed)
      local by_id, new = {}, {}
      for _, d in ipairs(s.state.drafts) do
        if d.id then by_id[d.id] = d end
        if d.origin == 'ai' and d.state == 'pending' then new[#new + 1] = d end
      end
      assert.is_nil(by_id['p-a'])
      assert.is_nil(by_id['p-b'])
      assert.truthy(by_id.k and by_id.e and by_id.u)
      assert.equals(2, #new)
      assert.same({ 'src/a.lua', 'src/b.lua' }, {
        new[1].path,
        new[2].path,
      })
      assert.equals('blocker', new[1].severity)
      assert.truthy(new[1].id)
      -- The marker lives in the editor: the body is what the AI wrote
      assert.equals('ANSWERTEXT about src/a.lua', new[1].body)
    end)

    it('sends the PR and the diff, but not the generated files', function()
      ai.run(s)
      local text = sent[1].text
      assert.equals('/repo', sent[1].root)
      assert.is_truthy(text:find('feat: x', 1, true))
      assert.is_truthy(text:find('Body of the PR', 1, true))
      assert.is_truthy(text:find('DIFFTEXT of src/a.lua', 1, true))
      assert.is_falsy(text:find('go.sum', 1, true))
      local said =
        table.concat(vim.tbl_map(function(n) return n.msg end, notes), '\n')
      assert.is_truthy(said:find('go.sum', 1, true))
    end)

    it('hands the paths of every chunk to the sensitive-path check', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 30)
      ai.run(s)
      assert.equals(2, #sent)
      assert.same({ 'src/a.lua' }, sent[1].paths)
      assert.same({ 'src/b.lua', 'src/old_b.lua' }, sent[2].paths)
    end)

    it('names a failed chunk and keeps what the others found', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 30)
      failing['src/b.lua'] = true
      ai.run(s)
      assert.equals(1, changed)
      local pending = vim.tbl_filter(
        function(d) return d.origin == 'ai' and d.state == 'pending' end,
        s.state.drafts
      )
      -- The new draft of the chunk that answered, and the old pending draft
      -- of the one that failed
      assert.same(
        { 'src/a.lua', 'src/b.lua' },
        vim.tbl_map(function(d) return d.path end, pending)
      )
      assert.equals('p-b', pending[2].id)
      local last = notes[#notes]
      assert.equals(vim.log.levels.WARN, last.level)
      assert.is_truthy(last.msg:find('src/b.lua', 1, true))
    end)

    it('changes nothing when every chunk fails', function()
      failing['src/a.lua'] = true
      local before = vim.deepcopy(s.state.drafts)
      ai.run(s)
      assert.equals(0, changed)
      assert.same(before, s.state.drafts)
      assert.equals(vim.log.levels.ERROR, notes[#notes].level)
    end)

    it('shows the summary in the panel and follows the order', function()
      ai.run(s)
      assert.equals('SUMMARYTEXT of src/a.lua src/b.lua', s.ai_summary)
      assert.same(
        { 'src/b.lua', 'src/a.lua' },
        vim.tbl_map(function(f) return f.path end, s.buckets[1].files)
      )
    end)

    it(
      'counts comments outside the diff and a chunk that does not read',
      function()
        stub(require('tools.ai.git'), 'MAX_DIFF', 30)
        answers = function(paths)
          if paths[1] == 'src/b.lua' then return 'ANSWERTEXT without JSON' end
          return vim.json.encode({
            comments = {
              { path = 'src/a.lua', line = 99, body = 'ANSWERTEXT far' },
              { path = 'src/a.lua', line = 3, body = 'ANSWERTEXT near' },
            },
          })
        end
        ai.run(s)
        answers = nil
        local text =
          table.concat(vim.tbl_map(function(n) return n.msg end, notes), '\n')
        assert.is_truthy(
          text:find('1 AI comment pointed outside the diff', 1, true)
        )
        assert.is_truthy(text:find('src/b.lua', 1, true))
      end
    )

    it('never notifies diff text or what the AI answered', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 30)
      failing['src/b.lua'] = true
      ai.run(s)
      failing = {}
      ai.run(s)
      assert.is_true(#notes > 0)
      for _, note in ipairs(notes) do
        assert.is_falsy(note.msg:find('DIFFTEXT', 1, true), note.msg)
        assert.is_falsy(note.msg:find('ANSWERTEXT', 1, true), note.msg)
        assert.is_falsy(note.msg:find('SUMMARYTEXT', 1, true), note.msg)
        assert.is_falsy(note.msg:find('Body of the PR', 1, true), note.msg)
      end
    end)

    --- Every notice, one a line
    local function said()
      return table.concat(
        vim.tbl_map(function(n) return n.msg end, notes),
        '\n'
      )
    end

    it('counts comments on files of another chunk or never sent', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 30)
      s.hunks['go.sum'] = { new = { { 1, 5 } }, old = {} }
      answers = function(paths)
        if paths[1] ~= 'src/a.lua' then return '{"comments": []}' end
        return vim.json.encode({
          comments = {
            { path = 'src/b.lua', line = 2, body = 'ANSWERTEXT b' },
            { path = 'go.sum', line = 2, body = 'ANSWERTEXT sum' },
            { path = 'src/a.lua', line = 2, body = 'ANSWERTEXT a' },
          },
        })
      end
      ai.run(s)
      local new = vim.tbl_filter(
        function(d) return d.origin == 'ai' and d.state == 'pending' end,
        s.state.drafts
      )
      assert.same(
        { 'src/a.lua' },
        vim.tbl_map(function(d) return d.path end, new)
      )
      assert.is_truthy(
        said():find('2 AI comments pointed outside the diff', 1, true)
      )
    end)

    it('counts comments past the end of a cut diff', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 33)
      local git = require('tools.review.git')
      stub(
        git,
        'diff',
        function(_, _, _, _, _, cb)
          cb({
            ['src/a.lua'] = '@@ -1,0 +1,5 @@\n+one\n+two\n+three\n+four\n+five\n',
            ['src/b.lua'] = 'b\n',
          }, nil, false)
        end
      )
      answers = function(paths)
        if paths[1] ~= 'src/a.lua' then return '{"comments": []}' end
        return vim.json.encode({
          comments = {
            { path = 'src/a.lua', line = 2, body = 'ANSWERTEXT seen' },
            { path = 'src/a.lua', line = 5, body = 'ANSWERTEXT unseen' },
            {
              path = 'src/a.lua',
              line = 4,
              start_line = 2,
              body = 'ANSWERTEXT across',
            },
          },
        })
      end
      ai.run(s)
      local new = vim.tbl_filter(
        function(d) return d.origin == 'ai' and d.state == 'pending' end,
        s.state.drafts
      )
      assert.equals(1, #new)
      assert.equals(2, new[1].line)
      assert.is_truthy(
        said():find('2 AI comments pointed outside the diff', 1, true)
      )
    end)

    it('names a file whose hunks could not be read as failed', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 30)
      local git = require('tools.review.git')
      stub(git, 'hunks', function(_, _, _, path, _, cb)
        if path == 'src/b.lua' then return cb(nil, 'boom') end
        cb({ new = { { 1, 5 } }, old = {} })
      end)
      ai.run(s)
      local text = said()
      assert.is_falsy(text:find('outside', 1, true))
      assert.is_truthy(text:find('failed for src/b.lua', 1, true))
      local ids = vim.tbl_map(function(d) return d.id end, s.state.drafts)
      assert.is_true(vim.tbl_contains(ids, 'p-b'))
    end)

    it('counts an answer that raises as a failed chunk', function()
      stub(require('tools.ai.git'), 'MAX_DIFF', 30)
      local parse = ai.parse
      stub(ai, 'parse', function(answer, hunks, opts)
        if hunks['src/b.lua'] then error('boom') end
        return parse(answer, hunks, opts)
      end)
      ai.run(s)
      assert.equals(1, changed)
      assert.is_truthy(said():find('failed for src/b.lua', 1, true))
      notes = {}
      ai.run(s)
      assert.is_falsy(said():find('running already', 1, true))
      assert.equals(2, changed)
    end)

    it('keeps nothing once the review has closed', function()
      stub(session_mod, 'current', function() return nil end)
      local before = vim.deepcopy(s.state.drafts)
      ai.run(s)
      assert.equals(0, changed)
      assert.same(before, s.state.drafts)
    end)
  end)
end)
