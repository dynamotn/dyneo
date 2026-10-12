--- Settings shared across the whole configuration
---
--- They live in the one global table `DyNeo`, named after the configuration,
--- instead of each taking a name of its own in `_G`. Their declarations,
--- defaults and types sit together in this file, and `per_machine` is loaded
--- afterwards and is free to override every one of them.

---@class DyNeo
_G.DyNeo = _G.DyNeo or {}

---@type boolean Flag to set background. Read as the manual choice whenever
--- `DyNeo.day_night.enabled` is off, and overwritten by the clock when it is on.
DyNeo.dark_mode = true

---@class DyDayNight
---@field enabled boolean Let the clock decide `DyNeo.dark_mode`
---@field day_start integer Hour the light half begins, 0-23
---@field night_start integer Hour the dark half begins, 0-23

---@type DyDayNight When to be light and when to be dark. Turn `enabled` off
--- on a machine that should stay on whatever `DyNeo.dark_mode` says.
DyNeo.day_night = {
  enabled = false,
  day_start = 6,
  night_start = 18,
}

---@type boolean Flag to install all plugins, useful for update `lazy-lock.json`
DyNeo.used_full_plugins = false

---@alias DyPluginChannel
---| 'latest' # Every plugin at its newest commit; needs a Neovim nightly
---| 'stable' # Every plugin that tags releases on its newest release

---@type DyPluginChannel What `:Lazy update` moves plugins to. `latest` gets
--- fixes the day they land and breakage with them; `stable` trades that for
--- releases the plugin authors vouched for, and a released Neovim. Each keeps
--- its own lockfile, so machines on different channels never rewrite each
--- other's pins.
DyNeo.plugin_channel = vim.fn.has('nvim-0.13') == 1 and 'latest' or 'stable'

---@type integer Seconds a release has to have been out before it may be
--- installed, by Mason (`tools.mason-quarantine`) or by lazy.nvim
--- (`tools.lazy-quarantine`) alike. It is the same week `min-release-age`
--- (npm), `minimumReleaseAge` (bun, pnpm) and `exclude-newer` (uv) give the
--- rest of these dotfiles, so a compromised release has time to be caught
--- and pulled before it lands here. Raise it on a machine that can afford to
--- wait longer; `0` turns the wait off and is what a machine being set up
--- from nothing may need.
DyNeo.quarantine_window = 7 * 24 * 60 * 60

---@alias DyAiTarget
---| 'avante' # Avante's sidebar, with whatever provider it is on
---| 'sidekick' # The AI CLI sidekick has open in its terminal

---@class DyAi
---@field target DyAiTarget Where `:DyAi` sends a prompt
---@field commit_command string[] Command writing a commit message, given the
--- prompt and the staged diff on its standard input. It runs with no terminal,
--- so it must answer on standard output without asking anything.
---@field commit_timeout integer Milliseconds `commit_command` may take
---@field local_only string[] Folders whose code may only go to an AI on this
--- machine, besides any project with a `.nvim/ai.json` saying so
---@field local_providers string[] Avante providers that run on this machine
---@field local_command? string[] What writes a commit message or a pull
--- request in a folder kept local, as `commit_command` does elsewhere: a
--- model of Ollama, say. Unset, those are refused there.

---@type DyAi The AI actions of `tools.ai`. Avante speaks to every provider
--- it knows, so it is where prompts go unless a machine prefers the CLI in
--- sidekick; a commit message wants one quick answer, which a headless
--- `claude -p` gives without a chat around it.
DyNeo.ai = {
  target = 'avante',
  commit_command = { 'claude', '-p' },
  commit_timeout = 90 * 1000,
  local_only = {},
  local_providers = { 'ollama' },
  local_command = nil,
}

---@class DyEnabledPlugins
---@field obsidian boolean
---@field leetcode boolean
---@field otter boolean
---@field firenvim boolean
---@field chezmoi boolean

---@type DyEnabledPlugins List of flag to enable each misc plugin
DyNeo.enabled_plugins = {
  obsidian = false,
  leetcode = false,
  otter = false,
  firenvim = false,
  chezmoi = false,
}

---@type string[] List enable each language, useful for install only plugins
--- for needed language. Default is all supported languages.
--- Sorted: what is built from it walks it in order, and `pairs` has none.
DyNeo.enabled_languages = vim.tbl_keys(require('config.languages'))
table.sort(DyNeo.enabled_languages)

---@type string[] List bundle language, include TS parsers, LSP servers, DAP
--- adapters, Linters and Formatters. Useful for containerize
DyNeo.bundle_languages = {}

---@type string[] Name of completion sources, display when show completion menu
DyNeo.completion_sources = {}

---@type string[] Directories of JSON and YAML schemas on this machine, offered
--- by the YAML schema picker next to those it finds in the project
DyNeo.yaml_schema_dirs = {}

---@type string Test strategy for vim-test
DyNeo.test_strategy = 'toggleterm'
if vim.env.ZELLIJ ~= nil then DyNeo.test_strategy = 'zellij' end

---@type fun(...): ... Custom code for better inspection
_G.dd = function(...) require('snacks.debug').inspect(...) end

-- `:lua =expr` and a fair number of plugins go through `vim.print`, and they
-- expect their arguments handed straight back. Snacks' notifier also wants a
-- UI to draw on, so the built-in keeps the job wherever there is none, such as
-- `--headless` and `nvim -l`.
--
-- Whether a UI is attached is remembered rather than asked on every call:
-- `nvim_list_uis` throws in a fast event context, and `print` reaches here
-- from libuv callbacks -- a Mason install is one of them. The built-in copes
-- with a fast event, the notifier does not, so that case goes to it as well.
local builtin_print = vim.print
local has_ui = #vim.api.nvim_list_uis() > 0
vim.api.nvim_create_autocmd({ 'UIEnter', 'UILeave' }, {
  group = vim.api.nvim_create_augroup('dy_print_ui', { clear = true }),
  -- Counted once the event is over: a UI on its way out is still listed while
  -- `UILeave` runs.
  callback = function()
    vim.schedule(function() has_ui = #vim.api.nvim_list_uis() > 0 end)
  end,
})
vim.print = function(...)
  -- Before `lazy.setup` snacks is not on the runtimepath yet
  if not has_ui or vim.in_fast_event() or not package.loaded.snacks then
    return builtin_print(...)
  end
  _G.dd(...)
  return ...
end

---@class DyObsidian
---@field paths table<string, string> Vault name to its folder
---@field vaults fun(): { name: string, path: string }[]
---@field todo_path fun(): string

-- Built in one piece: the fields are read back through `DyNeo.obsidian`, so
-- `per_machine` can still swap any of them out afterwards.
---@type DyObsidian Obsidian vaults
DyNeo.obsidian = {
  paths = {
    personal = vim.fn.expand('$HOME/Documents/Notes'),
  },
  vaults = function()
    local result = {}
    for name, path in pairs(DyNeo.obsidian.paths) do
      table.insert(result, {
        name = name,
        path = path,
      })
    end
    return result
  end,
  todo_path = function()
    return DyNeo.obsidian.paths.personal .. '/01_Fleeting/TODO.md'
  end,
}

---@type table<string, { priority: integer, takeover: string }> Firenvim setting
DyNeo.firenvim_site_settings = {}

---@type string Folder of word lists (`*.txt`), fed to the dictionary
--- completion source and to `:DySpell`. Nothing breaks when it is missing:
--- completion just has no dictionary words.
DyNeo.dictionaries_path = vim.fs.joinpath(
  vim.env.XDG_CONFIG_HOME or vim.fn.expand('~/.config'),
  'dictionaries'
)

---@type string Where locally developed plugins are checked out, for `dev` specs.
--- `NVIM_DEV_PLUGINS` points it elsewhere without editing any file, and
--- `per_machine` may still override it. The folder need not exist: lazy.nvim
--- falls back to the git remote for any plugin missing from it.
DyNeo.dev_plugins_path = vim.env.NVIM_DEV_PLUGINS or '~/Working/community/nvim'
