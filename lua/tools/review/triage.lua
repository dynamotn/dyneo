--- Group a pull request's changed files by kind and order the source files by
--- risk, so a reviewer of a very large change knows what to read first.
---
--- Pure: paths in, groups out. Every pattern is a Lua pattern matched against
--- the lower-cased, forward-slash path with a leading `/`, so `/vendor/` means
--- a directory named exactly `vendor` at any depth, never `redistribute`. The
--- tables are upper-case fields so a spec or a user can change them.

---@alias DyReviewKind 'source'|'tests'|'config'|'docs'|'generated'

---@class DyReviewFile
---@field path string
---@field old_path? string
---@field status 'A'|'M'|'D'|'R'
---@field added integer
---@field removed integer
---@field kind DyReviewKind
---@field risk integer 0 = none, higher reads first
---@field binary boolean

---@class DyReviewBucket
---@field kind DyReviewKind
---@field files DyReviewFile[]
---@field added integer
---@field removed integer

local M = {}

--- Buckets in the order a reviewer meets them.
---@type DyReviewKind[]
M.ORDER = { 'source', 'tests', 'config', 'docs', 'generated' }

--- Files nobody reads line by line: lockfiles, vendored and built output,
--- generated code, snapshots.
---@type string[]
M.GENERATED = {
  '/vendor/',
  '/node_modules/',
  '/dist/',
  '/__snapshots__/',
  '%.snap$',
  '%.lock$',
  '/package%-lock%.json$',
  '/npm%-shrinkwrap%.json$',
  '/pnpm%-lock%.yaml$',
  '/go%.sum$',
  '/lazy%-lock[^/]*%.json$',
  '/poetry%.lock$',
  '%.min%.%w+$',
  '%.pb%.go$',
  '%.pb%.%w+$',
  '_generated%.%w+$',
  '%.generated%.%w+$',
}

--- Test code, by directory or by file-name convention.
---@type string[]
M.TESTS = {
  '/tests?/',
  '/__tests__/',
  '/spec/',
  '_tests?%.%w+$',
  '%.tests?%.%w+$',
  '_spec%.%w+$',
  '%.spec%.%w+$',
  '/test_[^/]*$',
}

--- Prose.
---@type string[]
M.DOCS = {
  '/docs?/',
  '%.md$',
  '%.mdx$',
  '%.rst$',
  '%.adoc$',
  '/license[^/]*$',
  '/changelog[^/]*$',
}

--- Build, CI, infrastructure and settings files.
---@type string[]
M.CONFIG = {
  '/%.github/',
  '/%.gitlab%-ci%.ya?ml$',
  '/dockerfile[^/]*$',
  '/containerfile[^/]*$',
  '/makefile$',
  '/docker%-compose[^/]*$',
  '%.tf$',
  '%.tfvars$',
  '/k8s/',
  '/kubernetes/',
  '/helm/',
  '/charts/',
  '%.ya?ml$',
  '%.toml$',
  '%.json$',
  '%.ini$',
  '%.cfg$',
  '/%.[^/]+rc$',
}

--- What deserves attention first, by weight; the heaviest match wins. Order:
--- auth, crypto, security, permissions and secrets; migrations and schemas;
--- CI, container, Terraform and Kubernetes files; public API definitions.
---@type { [1]: string, [2]: integer }[]
M.RISK = {
  { '%f[%a]auth%f[%A]', 100 },
  { 'authn', 100 },
  { 'authz', 100 },
  { 'authenticat', 100 },
  { 'authoriz', 100 },
  { 'oauth', 100 },
  { 'crypto', 100 },
  { '%f[%a]tls', 100 },
  { 'jwt', 100 },
  { '%f[%a]tokens?%f[%A]', 100 },
  { 'secur', 100 },
  { 'permission', 100 },
  { 'passw', 100 },
  { 'secret', 100 },
  { 'credential', 100 },
  { '/migrations?/', 60 },
  { '/schemas?/', 60 },
  { '%.sql$', 60 },
  { '/%.github/workflows/', 40 },
  { '/%.gitlab%-ci%.ya?ml$', 40 },
  { '/dockerfile[^/]*$', 40 },
  { '%.tf$', 40 },
  { '/k8s/', 40 },
  { '/kubernetes/', 40 },
  { '/helm/', 40 },
  { '%.proto$', 30 },
  { '%.graphql$', 30 },
  { '/openapi[^/]*$', 30 },
  { '/swagger[^/]*$', 30 },
  { '/api/', 30 },
}

---@param path string
---@return string
local function normalize(path)
  return '/' .. path:gsub('\\', '/'):gsub('^%./', ''):lower()
end

---@param p string normalized path
---@param patterns string[]
---@return boolean
local function any(p, patterns)
  for _, pat in ipairs(patterns) do
    if p:find(pat) then return true end
  end
  return false
end

--- The kind of a changed file. A `generated` or `vendored` attribute (from
--- `git check-attr`) wins over every path rule.
---@param path string
---@param attrs? { generated?: boolean, vendored?: boolean }
---@return DyReviewKind
function M.classify(path, attrs)
  if attrs and (attrs.generated or attrs.vendored) then return 'generated' end
  local p = normalize(path)
  if any(p, M.GENERATED) then return 'generated' end
  if any(p, M.TESTS) then return 'tests' end
  if any(p, M.DOCS) then return 'docs' end
  if any(p, M.CONFIG) then return 'config' end
  return 'source'
end

--- How much attention a path deserves; 0 means none in particular.
---@param path string
---@return integer
function M.risk(path)
  -- An upper-case letter after a lower-case one starts a word, so
  -- `AuthService` reads as `auth_service` while `author` stays one word.
  local p = normalize((path:gsub('(%l)(%u)', '%1_%2')))
  local best = 0
  for _, rule in ipairs(M.RISK) do
    if rule[2] > best and p:find(rule[1]) then best = rule[2] end
  end
  return best
end

---@param files DyReviewFile[]
---@param ai_order? string[]
local function sort_source(files, ai_order)
  local pos = {}
  for i, path in ipairs(ai_order or {}) do
    pos[path] = pos[path] or i
  end
  table.sort(files, function(a, b)
    local pa, pb = pos[a.path] or math.huge, pos[b.path] or math.huge
    if pa ~= pb then return pa < pb end
    if a.risk ~= b.risk then return a.risk > b.risk end
    local ca, cb = a.added + a.removed, b.added + b.removed
    if ca ~= cb then return ca > cb end
    return a.path < b.path
  end)
end

--- Group files into buckets in `M.ORDER`, leaving empty ones out. Source files
--- follow `ai_order` when given (the AI's reading order wins), then risk, then
--- churn; the other buckets are sorted by path. The input is not modified.
---@param files DyReviewFile[]
---@param ai_order? string[]
---@return DyReviewBucket[]
function M.buckets(files, ai_order)
  ---@type table<string, DyReviewBucket>
  local by_kind = {}
  for _, f in ipairs(files) do
    local kind = vim.tbl_contains(M.ORDER, f.kind) and f.kind or 'source'
    local bucket = by_kind[kind]
    if not bucket then
      bucket = { kind = kind, files = {}, added = 0, removed = 0 }
      by_kind[kind] = bucket
    end
    bucket.files[#bucket.files + 1] = f
    bucket.added = bucket.added + f.added
    bucket.removed = bucket.removed + f.removed
  end
  local out = {}
  for _, kind in ipairs(M.ORDER) do
    local bucket = by_kind[kind]
    if bucket then
      if kind == 'source' then
        sort_source(bucket.files, ai_order)
      else
        table.sort(bucket.files, function(a, b) return a.path < b.path end)
      end
      out[#out + 1] = bucket
    end
  end
  return out
end

return M
