--- Whether a project may run its own code, asked once per root
---
--- A tool that loads a project's configuration or binaries runs that code
--- as the user. Its caller asks here first; the verdict is kept for the
--- session, per purpose and per real path of the root, and pinned to "no"
--- before the prompt, which keeps handling events and could ask again.
local M = {}

---@type table<string, table<string, boolean>>
local verdicts = {}

--- Whether code under `dir` may run for `purpose`, asked with `question`
--- the first time. A refusal is asked again on the next call unless
--- `sticky`, for a caller that asks without being asked (a server start).
---@param purpose string What runs, keeping verdicts apart: `deps`, `likec4`
---@param dir string
---@param question string
---@param sticky? boolean Keep a refusal for the session too
---@return boolean
function M.ask(purpose, dir, question, sticky)
  dir = vim.fs.normalize(vim.uv.fs_realpath(dir) or dir)
  verdicts[purpose] = verdicts[purpose] or {}
  local known = verdicts[purpose]
  if known[dir] ~= nil then return known[dir] end
  known[dir] = false
  local yes = vim.fn.confirm(question, '&Run\n&Cancel', 2) == 1
  if yes or sticky then
    known[dir] = yes
  else
    known[dir] = nil
  end
  return yes
end

return M
