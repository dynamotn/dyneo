-- Where the scripts find `dynamotn/mason-registry`, the plugin behind the
-- `lua:dy-mason-registry` registry. They run with `--clean`, so lazy.nvim
-- has put nothing on the runtimepath for them.
--
--   local plugin = dofile(root .. '/scripts/lib/mason_registry.lua').dir(root)

local M = {}

--- The plugin's checkout: a `dev` one under `DyNeo.dev_plugins_path` first,
--- as lazy.nvim takes that over its own clone, then that clone
---@param root string The configuration, for its `DyNeo` defaults
---@return string? dir Nil when neither has the registry
function M.dir(root)
  vim.opt.runtimepath:prepend(root)
  pcall(require, 'config.globals')
  pcall(require, 'per_machine.config')
  local data = vim.fn.stdpath('data') --[[@as string]]
  local candidates = { vim.fs.joinpath(data, 'lazy', 'mason-registry') }
  local dev = (rawget(_G, 'DyNeo') or {}).dev_plugins_path
  if type(dev) == 'string' then
    table.insert(
      candidates,
      1,
      vim.fs.joinpath(vim.fn.expand(dev), 'mason-registry')
    )
  end
  for _, dir in ipairs(candidates) do
    if
      vim.fn.filereadable(
        vim.fs.joinpath(dir, 'lua', 'dy-mason-registry', 'init.lua')
      ) == 1
    then
      return dir
    end
  end
end

return M
