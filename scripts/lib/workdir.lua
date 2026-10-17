-- A throwaway directory for the benchmarks to start Neovim on this tree
-- rather than on what `$HOME` has applied:
--
--   local workdir = dofile(root .. '/scripts/lib/workdir.lua')
--   local dir, config = workdir.config(root)  -- XDG_CONFIG_HOME = config
--
-- A child started with `vim.system` keeps the environment it is given on top
-- of this one, `NVIM_APPNAME` among it, and Neovim reads its configuration
-- from `$XDG_CONFIG_HOME/$NVIM_APPNAME`. The link is named after it, as
-- `check-startup.sh` does, so the `stable` channel measures itself and not an
-- empty configuration.

local M = {}

--- A new directory holding `config/<appname>`, a link to `root`
---@param root string
---@return string dir The directory, for the caller to delete
---@return string config What to set `XDG_CONFIG_HOME` to
function M.config(root)
  local dir = vim.fn.tempname()
  local config = dir .. '/config'
  vim.fn.mkdir(config, 'p')
  local appname = vim.env.NVIM_APPNAME
  if not appname or appname == '' then appname = 'nvim' end
  assert(vim.uv.fs_symlink(root, config .. '/' .. appname))
  return dir, config
end

return M
