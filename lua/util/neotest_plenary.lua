--- neotest-plenary, run from the project of the test file
---
--- Left to itself the adapter globs `**/testrc*` and `**/minimal_init*` from
--- the working directory on every run: on the main loop, through every file
--- below it, and taking whichever project's init it meets first. Here each
--- run gets the init of the test file's own project, looked up one level deep
--- once per project, and runs from that project's root, where the adapter's
--- `lua/?.lua` path expects to be.
---
--- The module is the adapter, for `adapters` in neotest's `opts` to name.

local M = {}

--- Where an init file is looked for under a project root, in order
M.PATTERNS = { '{minimal_init,testrc}*', '*/{minimal_init,testrc}*' }

---@type table<string, string|false> Init file per project root
local inits = {}

--- The init file of the project at `root`
---@param root string
---@return string? path
M.min_init = function(root)
  if inits[root] == nil then
    inits[root] = false
    for _, pattern in ipairs(M.PATTERNS) do
      -- `nio.fn` waits for the main loop when called from a fast event
      local found = require('nio').fn.globpath(root, pattern, false, true)
      table.sort(found)
      if found[1] then
        inits[root] = found[1]
        break
      end
    end
  end
  return inits[root] or nil
end

---@type neotest.Adapter?
local base

---@param args neotest.RunArgs
---@return neotest.RunSpec?
M.build_spec = function(args)
  local pos = args.tree and args.tree:data()
  if not pos then return end
  local create = require('neotest-plenary.adapter')
  local root = vim.fs.root(pos.path, 'lua') or vim.fs.dirname(pos.path)
  local spec =
    create({ min_init = M.min_init(root) or 'NONE' }).build_spec(args)
  if spec then spec.cwd = root end
  return spec
end

return setmetatable(M, {
  __index = function(_, key)
    base = base or require('neotest-plenary.adapter')({ min_init = 'NONE' })
    return base[key]
  end,
})
