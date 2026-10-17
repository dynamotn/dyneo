local M = {}

--- Whether the chezmoi plugins are part of this configuration
---
--- `chezmoi-template.nvim` injects the target language into every `*.tmpl`
--- once it is installed, so `plugin/predicates.lua` asks this before adding
--- its own injections by file name: both at once would parse each one twice.
---@return boolean
M.enabled = function()
  return DyNeo.used_full_plugins or DyNeo.enabled_plugins.chezmoi
end

return M
