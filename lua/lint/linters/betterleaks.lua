--- nvim-lint linter for `betterleaks`, the successor of `gitleaks`.
---
--- The buffer is piped in on standard input, so a secret is flagged while it
--- is being typed rather than once it is already on disk. Two of its defaults
--- are turned off on purpose:
---
--- - `--validation` sends every finding to the live API it belongs to, to
---   check whether the key still works. A secret must never leave the
---   machine, so it stays off.
--- - Findings carry the secret and the line around it; `--redact` blanks both
---   out, and only the rule is reported anyway.
---
--- It runs from the root of the buffer's project, which is where it looks for
--- `.betterleaks.toml`/`.gitleaks.toml` and their ignore files. Those come
--- with the repository and can allowlist every secret, which would also
--- clear the buffer for `util.sensitive`; so they are read only once
--- `vim.secure.read` has trusted them, as `exrc` is. Until then it runs from
--- an empty folder of its own, on its built-in rules.
---
--- Drop this file on the runtimepath as `lua/lint/linters/betterleaks.lua` and
--- nvim-lint picks it up by name:
---
---   require('lint').linters_by_ft['*'] = { 'betterleaks' }

--- Turn one finding into a diagnostic. Lines and columns are 1-based, and the
--- end column is the last character of the match.
---@param finding table One entry of the report
---@param bufnr integer
---@return vim.Diagnostic
local function to_diagnostic(finding, bufnr)
  return {
    bufnr = bufnr,
    lnum = finding.StartLine - 1,
    end_lnum = finding.EndLine - 1,
    col = finding.StartColumn - 1,
    end_col = finding.EndColumn,
    severity = vim.diagnostic.severity.WARN,
    source = 'betterleaks',
    code = finding.RuleID,
    message = finding.Description,
  }
end

--- Files of the project that change what is reported
local PROJECT_FILES = {
  '.betterleaks.toml',
  '.gitleaks.toml',
  '.betterleaksignore',
  '.gitleaksignore',
}

---@type table<string, boolean> Verdict per file and version, kept for the
--- session so that a lint never asks twice
local verdicts = {}
---@type table<string, boolean> Files already said to be ignored
local told = {}

--- Whether the file at `path` is trusted, asking once per version of it
---@param path string
---@param stat uv.fs_stat.result
---@return boolean
local function trusted(path, stat)
  local key = ('%s\0%d.%d'):format(path, stat.mtime.sec, stat.mtime.nsec)
  if verdicts[key] == nil then
    -- `vim.secure.read` goes on handling events while its prompt waits, so
    -- the verdict is pinned first: a lint arriving meanwhile does not ask
    -- again
    verdicts[key] = false
    verdicts[key] = vim.secure.read(path) ~= nil
    if not verdicts[key] and not told[path] then
      told[path] = true
      require('util.notify').titled('Lint')(
        ('betterleaks ignores %s: it is not trusted (`:trust` it)'):format(path),
        vim.log.levels.WARN
      )
    end
  end
  return verdicts[key]
end

--- The folder to run from: the project root when every file there that
--- tunes the scan is trusted, an empty folder of its own otherwise
---@param root string?
---@return string?
local function workdir(root)
  if not root then return nil end
  for _, file in ipairs(PROJECT_FILES) do
    local path = vim.fs.joinpath(root, file)
    local stat = vim.uv.fs_stat(path)
    if stat and not trusted(path, stat) then
      local empty = vim.fn.stdpath('cache') .. '/betterleaks'
      vim.fn.mkdir(empty, 'p')
      return empty
    end
  end
  return root
end

return function()
  local name = vim.api.nvim_buf_get_name(0)
  return {
    cmd = 'betterleaks',
    stdin = true,
    args = {
      'stdin',
      '--report-format=json',
      '--report-path=-',
      '--exit-code=0',
      '--no-banner',
      '--log-level=error',
      '--validation=false',
      '--redact',
    },
    cwd = workdir(name ~= '' and vim.fs.root(0, { '.git' }) or nil),
    stream = 'stdout',
    ignore_exitcode = false,
    parser = function(output, bufnr)
      local ok, findings = pcall(vim.json.decode, output)
      -- A clean run prints `[]`. Anything else unreadable is reported, not
      -- taken for clean: `util.sensitive` reads these findings, and holds the
      -- buffer back from the AI tools while this one stands.
      if not ok or type(findings) ~= 'table' then
        return {
          {
            lnum = 0,
            col = 0,
            severity = vim.diagnostic.severity.ERROR,
            source = 'betterleaks',
            code = 'unreadable-report',
            message = 'betterleaks gave a report that could not be read',
          },
        }
      end
      return vim.tbl_map(
        function(finding) return to_diagnostic(finding, bufnr) end,
        findings
      )
    end,
  }
end
