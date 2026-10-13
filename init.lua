-- The bytecode cache, ahead of lazy.nvim turning it on: `config.globals`
-- reads the whole language table before lazy.nvim loads
vim.loader.enable()
-- Globals shared across the configuration, with their defaults and types
require('config.globals')
-- Load specific configurations per machine. It runs ahead of the version
-- check because it may override `DyNeo.plugin_channel` (a nightly defaults
-- to `latest`, a release to `stable`), and the channel decides which Neovim
-- is new enough.
require('per_machine')

-- `latest` runs plugins at their newest commit, and those follow Neovim's
-- nightly. On their tagged releases nothing needs more than 0.12: that is
-- the floor several of them enforce themselves (nvim-treesitter `main`,
-- rustaceanvim, avante, native Copilot through
-- `vim.lsp.inline_completion`), and every 0.13 check found in them has a
-- fallback.
local version = DyNeo.plugin_channel == 'stable' and '0.12.0' or '0.13.0'
if vim.fn.has('nvim-' .. version) == 1 then
  -- Load lazy.nvim and the plugins
  require('config.lazy')
else
  vim.notify(
    'Neovim ' .. version .. ' or higher is required. Please update Neovim.',
    vim.log.levels.ERROR
  )
end
