-- Open a file of every language in the configuration `check-startup.sh` has
-- just loaded, and report every error that surfaces on the way.
--
-- Starting an empty Neovim only reaches `init.lua`: the `FileType`
-- dispatcher, the language servers, linters and formatters, and every plugin
-- that loads on a buffer event are left alone. Opening real files runs them.
--
-- A few things stand in the way of seeing what goes wrong, and are dealt with
-- here:
--
-- - Headless, the notifier has no UI to draw on and drops what it is sent, so
--   an error a handler reports through `vim.notify` never reaches the output.
--   Errors are copied to stderr, where the shell script looks for them.
--   Those raised while `init.lua` loads, before this file runs, were recorded
--   by `scripts/lib/notify-watch.lua`, which the shell script loads first.
-- - Opening a file installs whatever its language is missing. A check must
--   not download tools behind the user's back, so installs are recorded and
--   skipped instead -- and the names they were asked for are checked, since a
--   name nothing can install is the one mistake the real install would find.
-- - Headless there is nobody to answer a prompt, so prompts are cancelled.
-- - Headless no UI attaches, so `UIEnter` never fires, and neither does
--   lazy.nvim's `VeryLazy`, which waits for it: the plugins that load on
--   either, and the keymaps and autocmds `config.lazy` holds back for
--   `VeryLazy`, would never be loaded. The check fires `UIEnter` itself, as
--   attaching a UI does, before it opens a file.
-- - A plugin that loads only on a command or a key is never loaded by opening
--   files. Once they are open, every plugin still not loaded is, but for the
--   ones `samples.never_load` names.
-- - `config.languages` covers about a hundred languages, and a fixture file
--   for each would be a hundred files to keep in step with it. A tiny file per
--   filetype is written to a scratch directory instead, named so that
--   `vim.filetype.match` gives it that filetype.
--
-- The files, the skipped installs and the cancelled prompts come from
-- `scripts/lib/samples.lua`, which `scripts/bench-filetypes.lua` opens the
-- same files through: what is checked here and what is timed there are then
-- the same files, named the same way.
--
-- `CHECK_STARTUP_ALL=1` opens every filetype of every language; without it
-- only one file each of a spread of languages is, so the pre-commit hook
-- stays quick. `CHECK_STARTUP_WORKDIR` is where the generated files go, and
-- `CHECK_STARTUP_TRACE=1` names each file on stderr as it is opened, to find
-- the one a hang is stuck on, and each plugin as it is loaded.

local sweep_all = vim.env.CHECK_STARTUP_ALL == '1'

-- `check-startup.sh` points `XDG_CONFIG_HOME` at a directory whose `nvim` is
-- this repository, so the configuration Neovim found is the tree to load the
-- shared fixtures from.
local samples =
  dofile(vim.fs.joinpath(vim.fn.stdpath('config'), 'scripts/lib/samples.lua'))

-- Files of this repository itself, one per filetype. They hold real content,
-- which the empty generated files do not, so they stay even in the full sweep.
local repo_samples = {
  'init.lua',
  'scripts/check-startup.sh',
  '.pre-commit-config.yaml',
  'README.md',
  'renovate.json',
  '.stylua.toml',
}

-- Languages the quick run opens on top of the repository files: one of each
-- kind of wiring (servers with an `enabled` check, compound filetypes, files
-- told apart by path or by name, tools that are not from Mason).
local quick_languages = {
  'ansible',
  'bash',
  'dockerfile',
  'go',
  'helm',
  'javascript',
  'make',
  'python',
  'rust',
  'terraform',
  'typescript',
}

-- Shared with `scripts/lib/notify-watch.lua`, which filled it while the
-- configuration loaded
local errors = _G._dy_check_errors or {} ---@type string[]
_G._dy_check_errors = errors
---@type DyInstalls Filled in by `samples.skip_installs()` below
local installs

local function report(msg) table.insert(errors, tostring(msg)) end

-- Plugins swap `vim.notify` out as they load, so the wrapper is put back on
-- top after every file rather than installed once.
local function watch_notify()
  local current = vim.notify
  if rawequal(current, _G._dy_check_notify) then return end
  _G._dy_check_notify = function(msg, level, opts)
    if (level or vim.log.levels.INFO) >= vim.log.levels.ERROR then
      report(msg)
    end
    return current(msg, level, opts)
  end
  vim.notify = _G._dy_check_notify
end
watch_notify()

--- Report the recorded installs no real install could carry out
local function check_installs()
  local ok, registry = pcall(require, 'mason-registry')
  -- Without a registry on disk every name would look unknown, so the Mason
  -- half is only checked where there is one to ask.
  if ok and registry.sources:is_all_installed() then
    for _, name in ipairs(require('util.plugin').dedup(installs.mason)) do
      if not registry.has_package(name) then
        report(string.format('no Mason package `%s` to install', name))
      end
    end
  end
  if #installs.parser > 0 then
    -- What `nvim-treesitter.install` does before it looks a parser up: the
    -- parsers this configuration adds itself only exist after `TSUpdate`.
    package.loaded['nvim-treesitter.parsers'] = nil
    local parsers = require('nvim-treesitter.parsers')
    vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
    for _, name in ipairs(require('util.plugin').dedup(installs.parser)) do
      if not parsers[name] then
        report(string.format('no tree-sitter parser `%s` to install', name))
      end
    end
  end
end

--- Do what attaching a UI does, and wait for `VeryLazy` to have run
local function enter_ui()
  watch_notify()
  vim.api.nvim_exec_autocmds('UIEnter', { modeline = false })
  -- lazy.nvim fires `VeryLazy` from a scheduled callback, and sets this
  -- before it does
  local fired = vim.wait(
    5000,
    function() return vim.g.did_very_lazy == true end,
    10
  )
  if not fired then report('VeryLazy did not fire within 5s of UIEnter') end
  watch_notify()
end

--- Load every plugin that is not loaded yet, in sorted order
---@return integer loaded How many were loaded here
---@return string[] missing Plugins not installed, so not loaded
local function load_rest()
  local plugins = require('lazy.core.config').plugins
  local names = vim.tbl_keys(plugins)
  table.sort(names)
  local loaded, missing = 0, {}
  for _, name in ipairs(names) do
    local plugin = plugins[name]
    if
      plugin._.loaded
      or plugin._.cond == false
      or samples.never_load[name]
    then
      -- Loaded already, disabled on this machine, or unable to load headless
    elseif not plugin._.installed then
      table.insert(missing, name)
    else
      watch_notify()
      if vim.env.CHECK_STARTUP_TRACE then
        io.stderr:write('load ' .. name .. '\n')
      end
      local ok, err = pcall(require('lazy').load, { plugins = { name } })
      if not ok then report(name .. ': ' .. tostring(err)) end
      loaded = loaded + 1
    end
  end
  watch_notify()
  return loaded, missing
end

installs = samples.skip_installs()
local prompts = samples.skip_prompts()
samples.quiet_sidekick()
samples.quiet_octo()
samples.quiet_noice()
enter_ui()

local files = {} ---@type { path: string, filetype?: string, language?: string }[]
local config = vim.fn.stdpath('config') --[[@as string]]
for _, sample in ipairs(repo_samples) do
  table.insert(files, { path = vim.fs.joinpath(config, sample) })
end
local root = vim.env.CHECK_STARTUP_WORKDIR or vim.fn.tempname()
local generated, unmapped, count = samples.generate(
  vim.fs.joinpath(root, 'samples'),
  { all = sweep_all, languages = not sweep_all and quick_languages or nil }
)
vim.list_extend(files, generated)

-- Handlers and language servers start from callbacks, not from the `:edit`
-- itself. A short wait per file lets most of them run next to the file that
-- set them off; the long one at the end catches the stragglers.
local wait = sweep_all and 30 or 100
for _, file in ipairs(files) do
  watch_notify()
  if vim.env.CHECK_STARTUP_TRACE then
    io.stderr:write('open ' .. file.path .. '\n')
  end
  local ok, err = pcall(vim.cmd.edit, vim.fn.fnameescape(file.path))
  if not ok then
    report(err)
  elseif file.filetype and vim.bo.filetype ~= file.filetype then
    -- `vim.filetype.match` and `:edit` disagree: the language was never
    -- really opened, so it would pass without having been checked.
    report(
      string.format(
        '%s: opened as `%s`, expected `%s`',
        file.language,
        vim.bo.filetype,
        file.filetype
      )
    )
  end
  vim.wait(wait)
end
watch_notify()
local loaded, not_installed = load_rest()
vim.wait(1000)
check_installs()

io.stdout:write(
  string.format(
    'check-startup: opened %d files (%d filetypes of %d languages%s)\n',
    #files,
    #generated,
    count,
    sweep_all and '' or ', CHECK_STARTUP_ALL=1 for all'
  )
)
io.stdout:write(
  string.format('check-startup: loaded %d plugins nothing had loaded\n', loaded)
)
if #not_installed > 0 then
  io.stdout:write(
    'check-startup: not installed, so not loaded '
      .. table.concat(not_installed, ', ')
      .. '\n'
  )
end
if #unmapped > 0 then
  io.stdout:write(
    'check-startup: no file name for ' .. table.concat(unmapped, ', ') .. '\n'
  )
end
-- A filetype the sweep cannot open is a language it never checked
if sweep_all then
  for _, pair in ipairs(unmapped) do
    if not samples.unopened[pair] then
      report(
        pair .. ': no file name opens it, add one to scripts/lib/samples.lua'
      )
    end
  end
end
if #prompts > 0 then
  io.stdout:write(
    'check-startup: cancelled prompts '
      .. table.concat(require('util.plugin').dedup(prompts), ', ')
      .. '\n'
  )
end
for kind, names in pairs(installs) do
  if #names > 0 then
    io.stdout:write(
      string.format(
        'check-startup: skipped installing %s %s\n',
        kind,
        table.concat(require('util.plugin').dedup(names), ', ')
      )
    )
  end
end
--- Return the skipped package `msg` complains is missing, if it does
---
--- On a machine that has nothing installed -- CI -- a plugin that looks for
--- its tool as soon as the file opens finds it missing, because the install
--- that would have put it there was skipped by this check. That is the check
--- talking, not the configuration, so it is set apart rather than failed on.
--- Anything else about the same tool still fails.
---@param msg string
---@return string?
local function missing_skipped(msg)
  local lower = msg:lower()
  local missing = lower:find('not found')
    or lower:find('not executable')
    or lower:find('not installed')
    or lower:find('no such file')
  if not missing then return end
  -- As a word: `elp` or `jq` is part of many a message about something else
  for _, name in ipairs(installs.mason) do
    if msg:find('%f[%w_-]' .. vim.pesc(name) .. '%f[^%w_-]') then
      return name
    end
  end
end

local missing = {} ---@type string[]
for _, msg in ipairs(errors) do
  local name = missing_skipped(msg)
  if name then
    table.insert(missing, name)
  else
    io.stderr:write('Error: ' .. msg .. '\n')
  end
end
if #missing > 0 then
  io.stdout:write(
    'check-startup: missing because their install was skipped '
      .. table.concat(require('util.plugin').dedup(missing), ', ')
      .. '\n'
  )
end
vim.cmd('qa!')
