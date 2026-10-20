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
end)
