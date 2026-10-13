--- nvim-lint linter for `conftest`, the project's own Rego policies.
---
--- Runs only where there is a `policy/` directory, the one conftest reads by
--- default, in the directory of the file or above it, and passes it with
--- `--policy` so the working directory does not matter. A policy names no
--- line, so its findings land on the first one.

local M = {}

--- The `policy/` directory nearest above `file`
---@param file string
---@return string?
function M.policy_dir(file)
  if file == '' then return nil end
  return vim.fs.find('policy', {
    upward = true,
    type = 'directory',
    path = vim.fs.dirname(file),
  })[1]
end

--- The diagnostics of a `conftest test -o json` report
---@param output string
---@return vim.Diagnostic[]
--- What stands in for a report that could not be read, so a tool that
--- crashed never passes a file
---@type vim.Diagnostic
M.unreadable = {
  lnum = 0,
  col = 0,
  severity = vim.diagnostic.severity.ERROR,
  source = 'conftest',
  code = 'unreadable-report',
  message = 'conftest gave a report that could not be read',
}

function M.parse(output)
  -- No report is no clean run: the tool prints one even with nothing found
  if output == nil or output == '' then return { M.unreadable } end
  local ok, report =
    pcall(vim.json.decode, output, { luanil = { object = true, array = true } })
  if not ok or type(report) ~= 'table' then return { M.unreadable } end
  local diagnostics = {}
  local kinds = {
    { 'failures', vim.diagnostic.severity.ERROR },
    { 'warnings', vim.diagnostic.severity.WARN },
  }
  for _, file in ipairs(vim.islist(report) and report or {}) do
    for _, kind in ipairs(kinds) do
      for _, result in ipairs(type(file) == 'table' and file[kind[1]] or {}) do
        local code = vim.tbl_get(result, 'metadata', 'query')
        table.insert(diagnostics, {
          lnum = 0,
          col = 0,
          end_lnum = 0,
          severity = kind[2],
          message = result.msg or 'policy failed',
          code = code,
          source = 'conftest',
          user_data = { lsp = { code = code } },
        })
      end
    end
  end
  return diagnostics
end

--- Lint only Kubernetes manifests of a project that has policies
---@return boolean
function M.condition()
  return require('tools.kube').is_manifest(0)
    and M.policy_dir(vim.api.nvim_buf_get_name(0)) ~= nil
end

M.linter = {
  name = 'conftest',
  cmd = 'conftest',
  stdin = false,
  args = {
    'test',
    '--no-color',
    '--output',
    'json',
    '--policy',
    function() return M.policy_dir(vim.api.nvim_buf_get_name(0)) or 'policy' end,
  },
  stream = 'stdout',
  -- A failed policy is a non-zero exit
  ignore_exitcode = true,
  condition = M.condition,
  parser = M.parse,
}

return setmetatable(M.linter, { __index = M })
