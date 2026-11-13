--- `vim.version()` answered from one copy
---
--- It asks `vim.fn.api_info()` for the whole API description, about 2 ms a
--- call, and plugins call it as they load: nvim-lspconfig's `lsp/copilot.lua`
--- twice each time the file is read, every LSP client as it starts, satellite
--- in its setup. The version cannot change while Neovim runs.

local M = {}

--- Make `vim.version()` ask once and hand out copies of the answer
function M.memoize()
  local mt = getmetatable(vim.version)
  if mt.__dy_memoized then return end
  mt.__dy_memoized = true
  local call, version = mt.__call, nil
  mt.__call = function(...)
    version = version or call(...)
    -- A copy, so a caller changing what it got leaves the next answer alone
    return vim.deepcopy(version)
  end
end

return M
