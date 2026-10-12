--- nvim-lint linter for `semgrep`, static analysis of application code.
---
--- Runs only in a project with rules of its own -- `.semgrep.yml`,
--- `.semgrep.yaml` or a `.semgrep/` folder at its root -- and only on those
--- rules: never `--config auto` or a registry pack, which would fetch rules
--- and send the project's metadata to semgrep.dev. `--metrics=off` and
--- `--disable-version-check` keep the run itself off the network.
---
--- A rule that does not parse is reported on the first line rather than
--- read as a clean file.

local M = {}

M.CONFIGS = { '.semgrep.yml', '.semgrep.yaml', '.semgrep' }

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
    '--config',
    function() return M.config(0) end,
  },
  stream = 'stdout',
  -- A rule error is a non-zero exit, and its JSON says which
  ignore_exitcode = true,
  condition = function() return M.config(0) ~= nil end,
  parser = M.parse,
}

-- nvim-lint takes the module as the linter; the functions above ride along
-- for the specs
return setmetatable(M.linter, { __index = M })
