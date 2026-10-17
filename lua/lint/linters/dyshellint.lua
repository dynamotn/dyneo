--- nvim-lint linter for `dyshellint`, the linter of the Bash coding style guide.
---
--- The buffer is piped in on standard input, so a script is checked while it is
--- being written rather than only once it is saved. `--stdin-filename` carries
--- the real path along, which is what lets `dyshellint` find the `.shellcheckrc`
--- of the project and resolve `# shellcheck source=` directives.
---
--- Drop this file on the runtimepath as `lua/lint/linters/dyshellint.lua` and
--- nvim-lint picks it up by name:
---
---   require('lint').linters_by_ft.sh = { 'dyshellint' }

local severities = {
  error = vim.diagnostic.severity.ERROR,
  warning = vim.diagnostic.severity.WARN,
}

--- Name the buffer is reported under. An unnamed buffer still needs a name
--- that ends in `.sh`, because shfmt picks its dialect from the extension.
---@return string
local function stdin_filename()
  local name = vim.api.nvim_buf_get_name(0)
  if name == '' then return 'stdin.sh' end
  return name
end

--- Turn one finding into a diagnostic. `dyshellint` reports a position rather
--- than a range, so the diagnostic covers the single character it points at.
---@param finding table One entry of the `findings` array
---@return vim.Diagnostic
local function diagnostic(finding)
  local lnum = math.max((finding.line or 1) - 1, 0)
  local col = math.max((finding.column or 1) - 1, 0)
  return {
    lnum = lnum,
    col = col,
    end_lnum = lnum,
    end_col = col + 1,
    severity = severities[finding.severity] or vim.diagnostic.severity.WARN,
    message = finding.message,
    code = finding.rule,
    -- `source` is the tool behind the finding: dyshellint, shellcheck or shfmt.
    source = finding.source or 'dyshellint',
    user_data = {
      lsp = { code = finding.rule },
      -- The heading of the style guide the rule comes from, for a statusline
      -- or a mapping that opens the guide at the right place.
      section = finding.section,
    },
  }
end

--- What stands in for a report that could not be read, so a run that crashed
--- never passes a script
---@type vim.Diagnostic
local unreadable = {
  lnum = 0,
  col = 0,
  severity = vim.diagnostic.severity.ERROR,
  source = 'dyshellint',
  code = 'unreadable-report',
  message = 'dyshellint gave a report that could not be read',
}

return {
  name = 'dyshellint',
  cmd = 'dyshellint',
  stdin = true,
  -- The path travels in --stdin-filename, so nvim-lint must not append it.
  append_fname = false,
  args = {
    '--format',
    'json',
    '--stdin-filename',
    stdin_filename,
    '-',
  },
  stream = 'stdout',
  -- A non-zero status only means the buffer has findings.
  ignore_exitcode = true,
  ---@param output string The JSON report, printed even with nothing found
  ---@return vim.Diagnostic[]
  parser = function(output)
    local ok, report = pcall(vim.json.decode, output or '')
    if
      not ok
      or type(report) ~= 'table'
      or type(report.findings) ~= 'table'
    then
      return { vim.deepcopy(unreadable) }
    end
    local diagnostics = {}
    for _, finding in ipairs(report.findings) do
      table.insert(diagnostics, diagnostic(finding))
    end
    return diagnostics
  end,
}
