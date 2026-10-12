--- nvim-lint linter for `semgrep`, static analysis of application code.
---
--- Runs only in a project with rules of its own -- `.semgrep.yml`,
--- `.semgrep.yaml` or a `.semgrep/` folder at its root -- and only on those
--- rules: never `--config auto` or a registry pack, which would fetch rules
--- and send the project's metadata to semgrep.dev. `--metrics=off` and
--- `--disable-version-check` keep the run itself off the network.
---
--- Rules are code-like input a repository brings along, so they run only
--- once `vim.secure.read` has trusted them, as `exrc` is. semgrep reads the
--- file on disk, so a buffer with unwritten edits is left alone: the
--- positions would be those of the old text.
---
--- A rule that does not parse is reported on the first line rather than
--- read as a clean file.

local M = {}

M.CONFIGS = { '.semgrep.yml', '.semgrep.yaml', '.semgrep' }

--- Seconds a rule may spend on a file before semgrep gives it up
M.TIMEOUT = 5

--- MiB semgrep may use on a file before it gives the file up
M.MAX_MEMORY = 1024

local notify = require('util.notify').titled('Lint')

---@type table<string, boolean> Verdict per rules path and version, kept for
--- the session so that a lint never asks twice
local verdicts = {}
---@type table<string, boolean> Rules already said to be skipped
local told = {}
---@type number? When the trust database last changed, as `verdicts` knows it
local trust_mtime

local severities = {
  CRITICAL = vim.diagnostic.severity.ERROR,
  HIGH = vim.diagnostic.severity.ERROR,
  ERROR = vim.diagnostic.severity.ERROR,
  MEDIUM = vim.diagnostic.severity.WARN,
  WARNING = vim.diagnostic.severity.WARN,
  LOW = vim.diagnostic.severity.INFO,
  INFO = vim.diagnostic.severity.INFO,
}

--- The rules of the project of `bufnr`: the first of `M.CONFIGS` at its root
---@param bufnr integer
---@return string?
function M.config(bufnr)
  local root = vim.fs.root(bufnr, M.CONFIGS)
  if not root then return nil end
  for _, name in ipairs(M.CONFIGS) do
    local path = vim.fs.joinpath(root, name)
    if vim.uv.fs_stat(path) then return path end
  end
end

--- Whether the rules at `path` are trusted, asking once if they are not
--- known. A file is asked about again once it changes, as `:trust` keys it
--- by its contents; a folder is trusted by name.
---@param path string
---@return boolean
function M.trusted(path)
  -- `:trust` changes its database: a verdict taken back there must not live
  -- on here
  local db = vim.uv.fs_stat(vim.fn.stdpath('state') .. '/trust')
  local mtime = db and (db.mtime.sec * 1e9 + db.mtime.nsec) or 0
  if mtime ~= trust_mtime then
    trust_mtime, verdicts = mtime, {}
  end
  local stat = vim.uv.fs_stat(path)
  if not stat then return false end
  local key = ('%s\0%d.%d'):format(path, stat.mtime.sec, stat.mtime.nsec)
  if verdicts[key] == nil then
    -- `vim.secure.read` goes on handling events while its prompt waits, so
    -- the verdict is pinned first: a lint arriving meanwhile does not ask
    -- again
    verdicts[key] = false
    verdicts[key] = vim.secure.read(path) ~= nil
    if not verdicts[key] and not told[path] then
      told[path] = true
      notify(
        ('semgrep skipped: %s is not trusted (`:trust` it)'):format(path),
        vim.log.levels.WARN
      )
    end
  end
  return verdicts[key]
end

--- The diagnostics of a `semgrep scan --json` report
---@param output string
---@return vim.Diagnostic[]
function M.parse(output)
  local ok, report =
    pcall(vim.json.decode, output, { luanil = { object = true, array = true } })
  if not ok or type(report) ~= 'table' then
    report = { errors = { { message = 'semgrep gave no readable report' } } }
  end
  local diagnostics = {}
  for _, result in ipairs(report.results or {}) do
    local start, finish = result.start or {}, result['end'] or {}
    local extra = result.extra or {}
    table.insert(diagnostics, {
      lnum = math.max((start.line or 1) - 1, 0),
      col = math.max((start.col or 1) - 1, 0),
      end_lnum = finish.line and finish.line - 1,
      end_col = finish.col and finish.col - 1,
      severity = severities[extra.severity] or vim.diagnostic.severity.WARN,
      message = extra.message or result.check_id or 'semgrep finding',
      code = result.check_id,
      source = 'semgrep',
    })
  end
  for _, err in ipairs(report.errors or {}) do
    table.insert(diagnostics, {
      lnum = 0,
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = 'semgrep: ' .. (err.message or err.type or 'failed'),
      code = 'semgrep-error',
      source = 'semgrep',
    })
  end
  return diagnostics
end

M.linter = {
  name = 'semgrep',
  cmd = 'semgrep',
  stdin = false,
  args = {
    'scan',
    '--json',
    '--quiet',
    '--metrics=off',
    '--disable-version-check',
    '--timeout',
    tostring(M.TIMEOUT),
    '--max-memory',
    tostring(M.MAX_MEMORY),
    '--config',
    function() return M.config(0) end,
  },
  stream = 'stdout',
  -- A rule error is a non-zero exit, and its JSON says which
  ignore_exitcode = true,
  condition = function()
    if vim.bo.modified then return false end
    local config = M.config(0)
    return config ~= nil and M.trusted(config)
  end,
  parser = M.parse,
}

-- nvim-lint takes the module as the linter; the functions above ride along
-- for the specs
return setmetatable(M.linter, { __index = M })
