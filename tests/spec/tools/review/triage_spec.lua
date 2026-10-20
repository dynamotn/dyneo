local h = require('helpers')

---@param path string
---@param extra? table
---@return DyReviewFile
local function file(path, extra)
  return vim.tbl_extend('force', {
    path = path,
    status = 'M',
    added = 1,
    removed = 0,
    kind = 'source',
    risk = 0,
    binary = false,
  }, extra or {})
end

---@param files DyReviewFile[]
---@return string[]
local function paths(files)
  return vim.tbl_map(function(f) return f.path end, files)
end

describe('tools.review.triage', function()
  local triage

  before_each(function()
    h.unload('tools.review.triage')
    triage = require('tools.review.triage')
  end)

  describe('classify', function()
    local cases = {
      generated = {
        'package-lock.json',
        'go.sum',
        'lazy-lock.stable.json',
        'vendor/x.go',
        'dist/a.js',
        'a.min.js',
        'api.pb.go',
        'x_generated.go',
        '__snapshots__/a.snap',
        'web/package-lock.json',
      },
      tests = { 'foo_test.go', 'tests/spec/a_spec.lua', 'src/a.test.ts' },
      docs = { 'README.md', 'doc/x.txt' },
      config = {
        '.github/workflows/ci.yml',
        'Dockerfile',
        'infra/main.tf',
        'k8s/deploy.yaml',
      },
      source = { 'src/a.go', 'lua/a.lua' },
    }
    for kind, list in pairs(cases) do
      for _, path in ipairs(list) do
        it(
          ('puts %s in %s'):format(path, kind),
          function() assert.equals(kind, triage.classify(path)) end
        )
      end
    end

    it('honours the generated and vendored attributes', function()
      assert.equals(
        'generated',
        triage.classify('src/a.go', { generated = true })
      )
      assert.equals(
        'generated',
        triage.classify('src/a.go', { vendored = true })
      )
    end)

    it(
      'does not match a directory name inside a longer one',
      function()
        assert.equals('source', triage.classify('src/redistribute/a.go'))
      end
    )

    it(
      'normalizes backslashes',
      function() assert.equals('generated', triage.classify('vendor\\x.go')) end
    )
  end)

  describe('risk', function()
    it('ranks auth above migrations above plain code', function()
      local auth = triage.risk('src/auth/token.go')
      local mig = triage.risk('db/migrations/0042.sql')
      assert.is_true(auth > mig)
      assert.is_true(mig > 0)
      assert.equals(0, triage.risk('src/util/str.go'))
    end)
  end)

  describe('buckets', function()
    it('orders buckets, drops empty ones and totals lines', function()
      local out = triage.buckets({
        file('README.md', { kind = 'docs', added = 2, removed = 1 }),
        file('a.go', { added = 5, removed = 3 }),
        file('b.go', { added = 1, removed = 1 }),
        file('a_test.go', { kind = 'tests' }),
      })
      assert.same(
        { 'source', 'tests', 'docs' },
        vim.tbl_map(function(b) return b.kind end, out)
      )
      assert.equals(6, out[1].added)
      assert.equals(4, out[1].removed)
      assert.equals(2, out[3].added)
    end)

    it('sorts source by risk, then churn, then path', function()
      local out = triage.buckets({
        file('z.go', { added = 1 }),
        file('a.go', { added = 1 }),
        file('big.go', { added = 50 }),
        file('risky.go', { risk = 9 }),
      })
      assert.same({ 'risky.go', 'big.go', 'a.go', 'z.go' }, paths(out[1].files))
    end)

    it('lets the AI order win over risk', function()
      local out = triage.buckets({
        file('risky.go', { risk = 9 }),
        file('plain.go'),
        file('other.go', { risk = 5 }),
      }, { 'plain.go', 'other.go' })
      assert.same({ 'plain.go', 'other.go', 'risky.go' }, paths(out[1].files))
    end)

    it('sorts other buckets by path', function()
      local out = triage.buckets({
        file('b.md', { kind = 'docs', risk = 9 }),
        file('a.md', { kind = 'docs' }),
      })
      assert.equals('a.md', out[1].files[1].path)
    end)

    it(
      'returns nothing for no files',
      function() assert.same({}, triage.buckets({})) end
    )
  end)
end)
