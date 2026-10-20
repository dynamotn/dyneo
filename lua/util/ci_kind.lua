--- Which CI system a buffer defines a pipeline for
---
--- Read from the filetype, the file's name and, for plain YAML and Python,
--- its first lines, and nothing else: the `plugin/` shims ask it of every
--- Groovy, YAML and Python buffer that opens, before deciding to load
--- `tools.ci_inline`.
local M = {}

---@alias DyCiKind DyForgeKind|'jenkins'|'argo'|'airflow'|'prefect'|'dagster'

--- The data pipeline a Python file belongs to, by the module it imports, in
--- the order they are looked for
M.PYTHON = { 'airflow', 'prefect', 'dagster' }

--- Lines of a Python buffer read for its imports
M.PYTHON_SCAN = 200

--- The kinds of Argo Workflows that run, or define, a workflow
M.ARGO_KINDS = {
  Workflow = true,
  WorkflowTemplate = true,
  ClusterWorkflowTemplate = true,
  CronWorkflow = true,
}

--- Lines of a YAML buffer read to tell an Argo workflow
M.SCAN = 40

--- Whether `name` is a Jenkins pipeline: `Jenkinsfile`, `Jenkinsfile.ci`,
--- `deploy.jenkinsfile`
---@param name string The file's base name
---@return boolean
function M.is_jenkinsfile(name)
  return name:match('^Jenkinsfile') ~= nil
    or name:lower():match('%.jenkinsfile$') ~= nil
end

--- The Argo kind the first document of `lines` declares, if it is one
---@param lines string[]
---@return string?
function M.argo_kind(lines)
  local api, kind
  for _, line in ipairs(lines) do
    -- Only the first document speaks for the file
    if line:match('^%-%-%-') and (api or kind) then break end
    api = api or line:match('^apiVersion:%s*["\']?argoproj%.io/')
    kind = kind or line:match('^kind:%s*["\']?(%w+)')
  end
  return api and kind and M.ARGO_KINDS[kind] and kind or nil
end

--- The CI system `bufnr` defines a pipeline for
---@param bufnr integer
---@return DyCiKind?
function M.of(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == 'yaml.gitlab' then return 'gitlab' end
  if ft == 'yaml.gh-action' then return 'github' end
  if ft == 'yaml.az-pl' then return 'azure' end
  if ft == 'groovy' then
    local name = vim.fs.basename(vim.api.nvim_buf_get_name(bufnr))
    return M.is_jenkinsfile(name) and 'jenkins' or nil
  end
  if ft == 'yaml' then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, M.SCAN, false)
    return M.argo_kind(lines) and 'argo' or nil
  end
  if ft == 'python' then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, M.PYTHON_SCAN, false)
    local py = require('util.py_defs')
    for _, module in ipairs(M.PYTHON) do
      if py.imports(lines, module) then return module end
    end
  end
  return nil
end

return M
