-- Install lazy if not exist
local lazypath = vim.fn.stdpath('data') .. '/lazy/lazy.nvim'
if not vim.uv.fs_stat(lazypath) then
  local lazyrepo = 'https://github.com/folke/lazy.nvim.git'
  local out = vim.fn.system({
    'git',
    'clone',
    '--filter=blob:none',
    '--branch=stable',
    lazyrepo,
    lazypath,
  })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { 'Failed to clone lazy.nvim:\n', 'ErrorMsg' },
      { out, 'WarningMsg' },
      { '\nPress any key to exit...' },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
  -- The quarantine below cannot hold back the clone that brings it in, so the
  -- fresh checkout is walked back by hand: a machine set up the morning of a
  -- release would otherwise run that release the same day.
  require('tools.lazy-quarantine').bootstrap(lazypath)
end
-- Load lazy to runtime path
vim.opt.rtp:prepend(lazypath)

local Plugin = require('util.plugin')
local try = require('lazy.core.util').try
-- Hold notifications back until noice has replaced `vim.notify`, so the ones
-- sent while starting are not lost
Plugin.lazy_notify()
-- Options and leaders go in ahead of every plugin spec. A mistake in them is
-- reported, and the plugins still load.
try(
  function() require('config.options') end,
  { msg = 'Failed loading config.options' }
)
Plugin.snapshot_options()
if vim.g.deprecation_warnings == false then vim.deprecate = function() end end
-- Reaching the system clipboard can take a while, and nothing needs it before
-- `VeryLazy`
local clipboard = vim.o.clipboard
vim.o.clipboard = ''
-- `LazyFile`, for the specs that load once a real file is open
Plugin.lazy_file()

local defaults = require('config.defaults')
local stable = DyNeo.plugin_channel == 'stable'

-- Plugins whose newest release the config cannot run on, so on `stable` they
-- stay on their branch, the way `plugins.treesitter.parser` keeps
-- `nvim-treesitter` on its own. Each entry says why:
-- - "no release since": still developed on its branch, but the last tag is
--   more than two years old (as of 2026-10), and `version = '*'` would take
--   it back to that code;
-- - "lacks ...": the release is missing something the config uses.
-- `optional` keeps a plugin out when nothing else in the spec asks for it.
local stale_releases = {
  'stevearc/conform.nvim', -- v9.1.0 lacks `gdscript-formatter`
  'chrisgrieser/nvim-origami', -- `v1.9` is a pin to keep dropped options
  'willothy/flatten.nvim', -- v0.5.1 calls `hooks` `callbacks`
  'lewis6991/satellite.nvim', -- no release since v1.0.0 (2023-07)
  'folke/flash.nvim', -- no release since v2.1.0 (2024-07)
  'folke/ts-comments.nvim', -- v1.5.0 lacks its fix for Neovim 0.12
  'gbprod/yanky.nvim', -- no release since v2.0.0 (2023-11)
  'gpanders/nvim-parinfer', -- v1.2.0 lacks `vim.text.diff` for Neovim 0.12
  'honza/vim-snippets', -- no release since 1.0.0 (2014-05)
  'marilari88/neotest-vitest', -- no release since v0.2.0 (2022-09)
  'mfussenegger/nvim-dap', -- 0.10.0 lacks `listeners.on_session` (dap-view)
  'mfussenegger/nvim-jdtls', -- no release since 0.2.0 (2022-12)
  'nvim-lua/plenary.nvim', -- no release since v0.1.4 (2023-10)
  'tpope/vim-dadbod', -- no release since v1.4 (2021-08)
  'esensar/nvim-dev-container', -- no release since 0.2.0 (2022-05)
}
local stale_specs = vim.tbl_map(
  function(repo) return { repo, optional = true, version = false } end,
  stable and stale_releases or {}
)
-- Hold a plugin back for `DyNeo.quarantine_window` (a week unless a machine says
-- otherwise) after a commit or a release, the quarantine the npm, bun, pnpm,
-- uv and Mason sides of these dotfiles already apply. It goes in ahead of
-- `setup`, which installs what is missing as it runs.
try(
  function() require('tools.lazy-quarantine').setup() end,
  { msg = 'Failed setting up the plugin quarantine' }
)

-- The project's own `.nvim` folder, when it is trusted. Worked out here: the
-- runtimepath lazy.nvim builds has to name it.
local project_path = nil
try(
  function() project_path = require('util.project_rtp').startup_path() end,
  { msg = 'Failed checking the project .nvim folder' }
)

-- Setup lazy
require('lazy').setup({
  spec = {
    { 'folke/lazy.nvim', version = '*' },
    { import = 'plugins.ui' },
    { import = 'plugins.coding' },
    { import = 'plugins.treesitter' },
    { import = 'plugins.lsp' },
    { import = 'plugins.integration' },
    { import = 'plugins.executor' },
    { import = 'plugins.toolbox' },
    { import = 'plugins.lang' },
    stale_specs,
  },
  defaults = {
    lazy = true, -- Lazy loading all plugins
    -- `latest` prefers git commits over tagged releases. With `*`, a plugin
    -- that tags releases follows the newest one, and one that has never
    -- tagged any falls back to its branch, so nothing is left behind. A spec
    -- setting its own `version` or `branch` wins over this either way.
    version = stable and '*' or false,
  },
  -- The channels resolve to different commits, so sharing one lockfile would
  -- have every `:Lazy update` on one channel undo the other's pins.
  lockfile = vim.fn.stdpath('config')
    .. (stable and '/lazy-lock.stable.json' or '/lazy-lock.json'),
  install = { colorscheme = { defaults.colorscheme } },
  checker = {
    enabled = true, -- check for plugin updates periodically
    -- `latest` sees new commits every hour, so a notification would be
    -- noise. A new release on `stable` is rare and worth being told about.
    notify = stable,
  },
  performance = {
    cache = {
      enabled = true,
    },
    rtp = {
      -- The project's trusted `.nvim` folder survives the reset, and its
      -- `plugin/` is sourced with the rest
      paths = { project_path },
      -- disable some rtp plugins
      disabled_plugins = {
        'gzip',
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        'tarPlugin',
        'tohtml',
        'tutor',
        'zipPlugin',
      },
    },
  },
  ui = {
    custom_keys = {
      ['<localleader>d'] = function(plugin) dd(plugin) end,
    },
  },
  dev = {
    path = DyNeo.dev_plugins_path,
    patterns = {},
    -- Without a fallback, a `dev = true` plugin with no checkout under `path`
    -- is treated as a local plugin that is never cloned, so it fails to load
    -- on every machine but the one holding the checkouts. The Lazy UI still
    -- marks the plugins that do come from `path`.
    fallback = true,
  },
  debug = false,
  rocks = {
    enabled = false,
  },
})

-- Follow the project's `.nvim` folder as the working directory moves
try(
  function() require('util.project_rtp').setup() end,
  { msg = 'Failed following the project .nvim folder' }
)

-- A colorscheme that fails to load (not cloned yet, held back by the
-- quarantine) leaves a built-in one rather than stopping startup here
if not pcall(vim.cmd.colorscheme, defaults.colorscheme) then
  Plugin.warn(
    ('Colorscheme `%s` not found, using `habamax`'):format(defaults.colorscheme)
  )
  vim.cmd.colorscheme('habamax')
end

-- Opening files from the command line needs the autocmds from the start;
-- otherwise they wait with the keymaps for `VeryLazy`
local lazy_autocmds = vim.fn.argc(-1) == 0
local function load(name)
  try(function() require(name) end, { msg = 'Failed loading ' .. name })
end
if not lazy_autocmds then load('config.autocmds') end
Plugin.on_very_lazy(function()
  -- The clipboard and the helpers first, so a mistake in the keymaps cannot
  -- take format-on-save and the clipboard down with it
  vim.o.clipboard = clipboard
  require('util.format').setup()
  require('util.root').setup()
  require('util.rename').setup()
  if lazy_autocmds then load('config.autocmds') end
  load('config.keymaps')
  -- Spec fields of this configuration's own, for `:checkhealth lazy`
  vim.list_extend(require('lazy.health').valid, { 'vscode' })
end)
