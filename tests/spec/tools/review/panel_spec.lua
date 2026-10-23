local h = require('helpers')

describe('tools.review.panel', function()
  local panel

  before_each(function()
    h.unload('tools.review.panel')
    panel = require('tools.review.panel')
  end)

  local function file(path, kind, added, removed, fields)
    return vim.tbl_extend('force', {
      path = path,
      status = 'M',
      kind = kind,
      added = added,
      removed = removed,
      risk = 0,
      binary = false,
    }, fields or {})
  end

  local function ai(path)
    return {
      origin = 'ai',
      state = 'pending',
      path = path,
      side = 'new',
      line = 1,
      body = 'x',
    }
  end

  --- A pull request with a risky reviewed file, a changed one and a lockfile
  local function session(fields)
    local token = file('src/auth/token.go', 'source', 120, 4, {
      risk = 3,
      blob = 'b1',
    })
    local migration = file('db/migrations/0042_bill.sql', 'source', 88, 0, {
      risk = 2,
      blob = 'b2',
    })
    local export = file('src/billing/export.go', 'source', 612, 0, {
      blob = 'b3',
    })
    local lock = file('go.sum', 'generated', 9000, 7000, { blob = 'b4' })
    local s = {
      pull = { id = '412', title = 'feat: add billing export' },
      trusted = true,
      files = { token, migration, export, lock },
      buckets = {
        {
          kind = 'source',
          files = { token, migration, export },
          added = 820,
          removed = 4,
        },
        { kind = 'generated', files = { lock }, added = 9000, removed = 7000 },
      },
      state = {
        reviewed = {
          ['src/auth/token.go'] = 'b1',
          ['src/billing/export.go'] = 'old',
        },
        drafts = {
          ai('src/auth/token.go'),
          ai('src/auth/token.go'),
          ai('db/migrations/0042_bill.sql'),
          vim.tbl_extend(
            'force',
            ai('src/billing/export.go'),
            { state = 'kept' }
          ),
        },
      },
    }
    return vim.tbl_extend('force', s, fields or {})
  end

  describe('render', function()
    it('draws the header, buckets and files as the design shows', function()
      local lines, rows = panel.render(session())
      assert.same({
        ' PR !412  feat: add billing export   (1 of 4 files reviewed)',
        ' AI: 3 drafts to look at   ⟳ 1 file changed since last review',
        ' ▾ Source             3 files  +820 -4',
        '   ! ✓ src/auth/token.go            +120 -4   2 AI',
        '   !   db/migrations/0042_bill.sql  +88   1 AI',
        '     ⟳ src/billing/export.go        +612',
        ' ▸ Generated & locks  1 file   +9000 -7000   (collapsed)',
      }, lines)
      assert.same({ kind = 'source' }, rows[3])
      assert.equals('src/auth/token.go', rows[4].path)
      assert.equals('src/billing/export.go', rows[6].path)
      assert.same({ kind = 'generated' }, rows[7])
      assert.is_nil(rows[1])
    end)

    it('escapes control characters of a title and a path', function()
      local s = session({ trusted = false })
      s.pull.title = 'feat: x\nINJECTED\r\27[31m'
      s.files[1].path = 'src/a\nb.go'
      s.blocked = 'merged\nreally'
      local lines = panel.render(s)
      for _, line in ipairs(lines) do
        assert.is_nil(line:find('%c'), line)
      end
      assert.matches('feat: x^@INJECTED^M^[[31m', lines[1], 1, true)
      local row = vim.tbl_filter(
        function(line) return line:find('src/a^@b.go', 1, true) ~= nil end,
        lines
      )
      assert.equals(1, #row)
      -- What `nvim_buf_set_lines` refuses never reaches it
      local bufnr = h.buffer()
      assert.has_no.errors(
        function() vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines) end
      )
    end)

    it('shows the generated bucket once it is opened', function()
      local lines, rows =
        panel.render(session({ collapsed = { generated = false } }))
      assert.equals(' ▾ Generated & locks  1 file   +9000 -7000', lines[7])
      assert.equals('       go.sum                       +9000 -7000', lines[8])
      assert.equals('go.sum', rows[8].path)
    end)

    it('folds a bucket the reviewer closed', function()
      local lines = panel.render(session({ collapsed = { source = true } }))
      assert.equals(' ▸ Source             3 files  +820 -4', lines[3])
      assert.equals(
        ' ▸ Generated & locks  1 file   +9000 -7000   (collapsed)',
        lines[4]
      )
      assert.equals(4, #lines)
    end)

    it('says when the code is untrusted and why nothing can be sent', function()
      local lines = panel.render(session({
        trusted = false,
        blocked = 'The pull request is merged',
      }))
      assert.is_true(
        vim.tbl_contains(lines, ' Read only: The pull request is merged')
      )
      assert.is_true(
        vim.tbl_contains(
          lines,
          ' Diff only: no language server runs until `:DyReview trust`'
        )
      )
    end)

    it('says when the threads could not be read', function()
      local lines = panel.render(session({ threads_error = 'HTTP 500' }))
      assert.is_true(vim.tbl_contains(lines, ' Threads not read: HTTP 500'))
    end)

    it('leaves the summary line out when there is nothing to say', function()
      local s = session()
      s.state.reviewed = {}
      s.state.drafts = {}
      local lines = panel.render(s)
      assert.equals(
        ' PR !412  feat: add billing export   (0 of 4 files reviewed)',
        lines[1]
      )
      assert.equals(' ▾ Source             3 files  +820 -4', lines[2])
    end)

    it('shows the AI summary under the header, wrapped and capped', function()
      panel.SUMMARY_LINES = 3
      local lines = panel.render(session({
        ai_summary = 'Adds a billing export.\n\nThe token check moves to a new module and loses its expiry test. It also renames the config.',
      }))
      assert.same({
        ' AI summary:',
        '   Adds a billing export.',
        '   The token check moves to a new',
        '   …',
      }, vim.list_slice(lines, 3, 6))
      assert.equals(' ▾ Source             3 files  +820 -4', lines[7])
    end)

    it('names a binary file as such', function()
      local s = session()
      s.files[3].binary = true
      local lines = panel.render(s)
      assert.equals('     ⟳ src/billing/export.go        binary', lines[6])
    end)
    describe('CI line', function()
      local function run(state, by)
        return {
          provider = 'github',
          name = state,
          state = state,
          by = by or 'commit',
        }
      end

      it('is left out until a fetch has been asked for', function()
        local lines = panel.render(session())
        for _, line in ipairs(lines) do
          assert.is_nil(line:find('CI:', 1, true))
        end
      end)

      it('says it is asking while the first fetch runs', function()
        local s = session({ ci_loading = true })
        local lines, rows = panel.render(s)
        assert.equals(' CI: asking…', lines[2])
        assert.is_true(rows[2].ci)
      end)

      it('counts the runs by state', function()
        local runs = {}
        for _ = 1, 12 do
          runs[#runs + 1] = run('pass')
        end
        runs[#runs + 1] = run('fail')
        runs[#runs + 1] = run('running')
        runs[#runs + 1] = run('running')
        local lines, rows =
          panel.render(session({ ci = { runs = runs, errors = {} } }))
        assert.equals(' CI: 12 pass · 1 fail · 2 running', lines[2])
        assert.is_true(rows[2].ci)
      end)

      it('marks runs keyed on the branch', function()
        local lines = panel.render(session({
          ci = { runs = { run('pass'), run('fail', 'branch') }, errors = {} },
        }))
        assert.equals(' CI: 1 pass · 1 fail (by branch)', lines[2])
      end)

      it('names the sources it could not ask', function()
        local lines = panel.render(session({
          ci = {
            runs = {},
            errors = { 'github: boom: x', 'jenkins: HTTP 403' },
          },
        }))
        assert.equals(' CI: could not ask github, jenkins', lines[2])
      end)

      it('shows what other sources found beside a failed one', function()
        local lines = panel.render(session({
          ci = { runs = { run('pass') }, errors = { 'jenkins: HTTP 403' } },
        }))
        assert.equals(' CI: 1 pass · could not ask jenkins', lines[2])
      end)

      it('says a run is keyed by name, and what waits for trust', function()
        local lines = panel.render(session({
          ci = {
            runs = { run('running', 'name') },
            errors = {},
            waiting = { 'argo: after you trust the PR' },
          },
        }))
        assert.equals(
          ' CI: 1 running (by name) · argo: after you trust the PR',
          lines[2]
        )
        lines = panel.render(session({
          ci = {
            runs = {},
            errors = {},
            waiting = { 'argo: after you trust the PR' },
          },
        }))
        assert.equals(' CI: no runs · argo: after you trust the PR', lines[2])
      end)

      it('says when a head has no run', function()
        local lines = panel.render(session({ ci = { runs = {}, errors = {} } }))
        assert.equals(' CI: no runs', lines[2])
      end)
    end)
  end)

  describe('the panel window', function()
    local restores, calls

    before_each(function()
      calls = {}
      restores = {
        h.stub(
          require('util.plugin'),
          'safe_keymap_set',
          function(mode, lhs, rhs, opts) vim.keymap.set(mode, lhs, rhs, opts) end
        ),
        h.stub(package.loaded, 'tools.review', {
          show = function(path) calls[#calls + 1] = { 'show', path } end,
          mark = function(path) calls[#calls + 1] = { 'mark', path } end,
        }),
        h.stub(package.loaded, 'tools.review.ci', {
          STATES = require('tools.review.ci').STATES,
          pick = function(s) calls[#calls + 1] = { 'pick', s } end,
          load = function(s) calls[#calls + 1] = { 'load', s } end,
        }),
      }
    end)

    after_each(function()
      for i = #restores, 1, -1 do
        restores[i]()
      end
      vim.cmd('silent! tabonly | silent! only')
    end)

    --- The panel's window in the current tab
    local function panel_win(s)
      for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
        if vim.api.nvim_win_get_buf(win) == s.panel_buf then return win end
      end
    end

    --- Run the panel's buffer mapping of `lhs` with the cursor on `line`
    local function press(s, lhs, line)
      local win = panel_win(s)
      vim.api.nvim_set_current_win(win)
      vim.api.nvim_win_set_cursor(win, { line, 0 })
      local map = vim.fn.maparg(lhs, 'n', false, true)
      assert.equals(1, map.buffer)
      if map.callback then return map.callback() end
      vim.cmd((map.rhs:gsub('^<cmd>', ''):gsub('<cr>$', '')))
    end

    it('opens at the left, draws the files and keeps the focus', function()
      local s = session()
      local code = vim.api.nvim_get_current_win()
      panel.open(s)
      local win = panel_win(s)
      assert.is_not_nil(win)
      assert.equals(code, vim.api.nvim_get_current_win())
      assert.equals(panel.WIDTH, vim.api.nvim_win_get_width(win))
      assert.is_true(vim.wo[win].winfixwidth)
      assert.is_false(vim.wo[win].number)
      assert.equals('no', vim.wo[win].signcolumn)
      assert.equals('dyreview', vim.bo[s.panel_buf].filetype)
      assert.equals('nofile', vim.bo[s.panel_buf].buftype)
      assert.equals(
        ' ▾ Source             3 files  +820 -4',
        vim.api.nvim_buf_get_lines(s.panel_buf, 2, 3, false)[1]
      )
      assert.same({ kind = 'source' }, s.panel_rows[3])
    end)

    it('is not opened twice in a tab, and keeps its buffer', function()
      local s = session()
      panel.open(s)
      local bufnr = s.panel_buf
      local wins = #vim.api.nvim_tabpage_list_wins(0)
      panel.open(s)
      assert.equals(bufnr, s.panel_buf)
      assert.equals(wins, #vim.api.nvim_tabpage_list_wins(0))
    end)

    it('opens the file under the cursor, and does nothing off a row', function()
      local s = session()
      panel.open(s)
      press(s, '<CR>', 1)
      assert.same({}, calls)
      press(s, '<CR>', 4)
      assert.same({ { 'show', 'src/auth/token.go' } }, calls)
    end)

    it('folds and unfolds a bucket from its line', function()
      local s = session()
      panel.open(s)
      press(s, '<CR>', 3)
      assert.is_true(s.collapsed.source)
      assert.equals(
        ' ▸ Source             3 files  +820 -4',
        vim.api.nvim_buf_get_lines(s.panel_buf, 2, 3, false)[1]
      )
      assert.equals(4, vim.api.nvim_buf_line_count(s.panel_buf))
      press(s, '<CR>', 3)
      assert.is_false(s.collapsed.source)
      assert.equals(7, vim.api.nvim_buf_line_count(s.panel_buf))
    end)

    it('lists the CI runs from the CI line and refreshes them', function()
      local s = session({ ci = { runs = {}, errors = {} } })
      panel.open(s)
      press(s, '<CR>', 2)
      assert.same({ { 'pick', s } }, calls)
      press(s, 'r', 1)
      assert.same({ 'load', s }, calls[2])
    end)

    it('marks the file under the cursor, and only a file', function()
      local s = session()
      panel.open(s)
      press(s, 'm', 3)
      assert.same({}, calls)
      press(s, 'm', 5)
      assert.same({ { 'mark', 'db/migrations/0042_bill.sql' } }, calls)
    end)

    it('closes its window with q', function()
      local s = session()
      panel.open(s)
      press(s, 'q', 1)
      assert.is_nil(panel_win(s))
      assert.is_true(vim.api.nvim_buf_is_valid(s.panel_buf))
    end)

    it('follows the file shown in the diff', function()
      local s = session()
      panel.open(s)
      panel.follow(s, 'src/billing/export.go')
      assert.equals(6, vim.api.nvim_win_get_cursor(panel_win(s))[1])
      -- A path the panel does not list leaves the cursor where it is
      panel.follow(s, 'nowhere.go')
      assert.equals(6, vim.api.nvim_win_get_cursor(panel_win(s))[1])
    end)

    it('does nothing without a panel buffer', function()
      local s = session()
      assert.has_no.errors(function()
        panel.refresh(s)
        panel.follow(s, 'go.sum')
        panel.close(s)
      end)
      assert.is_nil(s.panel_buf)
    end)

    it('wipes its buffer and windows on close', function()
      local s = session()
      panel.open(s)
      local bufnr = s.panel_buf
      panel.close(s)
      assert.is_nil(s.panel_buf)
      assert.is_false(vim.api.nvim_buf_is_valid(bufnr))
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
    end)
  end)
end)
