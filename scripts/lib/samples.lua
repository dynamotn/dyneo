-- Fixtures and stubs shared by the scripts that load this configuration for
-- real and then open files in it.
--
-- `check-startup.lua` opens a file of every filetype to find the errors that
-- surface on the way, and `bench-filetypes.lua` opens the same files to time
-- them. Both need the same three things, and neither is a module on the
-- runtime path -- they are run with `luafile` and `-l` -- so this is loaded
-- with `dofile`:
--
--   local samples = dofile(root .. '/scripts/lib/samples.lua')
--
-- * A file per filetype, named so that `vim.filetype.match` gives it that
--   filetype. `config.languages` covers about a hundred languages, and a
--   fixture file for each would be a hundred files to keep in step with it,
--   so tiny files are written to a scratch directory instead.
-- * The installers stubbed out, so neither script downloads a Mason package,
--   a tree-sitter parser or a release binary behind the user's back. On a
--   machine that has nothing installed yet -- CI -- opening a file is itself
--   what starts the install, so the stubs go in before the plugin that owns
--   them runs its `config`.
-- * Prompts cancelled: headless there is nobody to answer one asked from a
--   `FileType` handler, and it would hang the script.
--
-- `keymaps-doc.lua` shares the last part, the stubs that keep the state of
-- the machine (Copilot not signed in) and the scripts' own `vim.notify`
-- wrapper out of the errors they fail on.

local M = {}

--- File names for the filetypes that no `sample.<filetype>` maps to: they are
--- known by their whole name, by the directory they sit in, or by an
--- extension named after something else. Paths are relative to the scratch
--- directory.
---@type table<string, string>
M.names_of = {
  arduino = 'sample.ino',
  automake = 'Makefile.am',
  blade = 'sample.blade.php',
  cmake = 'CMakeLists.txt',
  config = 'configure.ac',
  cucumber = 'sample.feature',
  dockerfile = 'Dockerfile',
  dosini = 'sample.ini',
  gitcommit = 'COMMIT_EDITMSG',
  gitrebase = 'git-rebase-todo',
  -- Away from `sample.go`: gopls takes an empty `go.mod` or `go.work` next
  -- to it for a broken module, and fails every request on the file
  gomod = 'gomodule/go.mod',
  gosum = 'gomodule/go.sum',
  gowork = 'goworkspace/go.work',
  helm = 'chart/templates/sample.yaml',
  htmlangular = 'sample.component.html',
  -- `templates/*.html` is Django only next to a `manage.py`
  htmldjango = 'sample.djhtml',
  ['bicep-params'] = 'sample.bicepparam',
  hyprlang = 'hypr/sample.conf',
  javascriptreact = 'sample.jsx',
  just = 'justfile',
  likec4 = 'sample.c4',
  make = 'Makefile',
  nextflow = 'sample.nf',
  nginx = 'nginx.conf',
  quarto = 'sample.qmd',
  query = 'queries/lua/highlights.scm',
  rmd = 'sample.Rmd',
  sh = 'sample.sh',
  snakemake = 'Snakefile',
  ['sh.PKGBUILD'] = 'PKGBUILD',
  structurizr = 'workspace.dsl',
  systemd = 'systemd/system/sample.service',
  ['terraform-vars'] = 'sample.tfvars',
  terragrunt = 'terragrunt.hcl',
  typescriptreact = 'sample.tsx',
  ['yaml.ansible'] = 'playbooks/sample.yml',
  ['yaml.az-pl'] = 'azure-pipelines.yml',
  ['yaml.docker-compose'] = 'docker-compose.yml',
  ['yaml.gh-action'] = '.github/workflows/sample.yml',
  ['yaml.gitlab'] = 'sample.gitlab-ci.yml',
  ['yaml.helm-values'] = 'chart/values.yaml',
}

--- `language/filetype` pairs no file name opens, and why: the sweep of
--- every language fails on any other one it cannot open
---@type table<string, string>
M.unopened = {
  ['bash/bats'] = 'Neovim opens a .bats file as `sh`',
  ['bash/sh.install'] = 'told by the contents of a `*.install` file',
  ['ini/ini'] = 'Neovim opens a .ini file as `dosini`',
  ['javascript/javascript.jsx'] = 'Neovim opens a .jsx file as `javascriptreact`',
  ['json/json.openapi'] = 'told by the `"openapi"` key of an `openapi*.json`',
  ['latex/plaintex'] = 'told by the contents of a .tex file',
  ['terraform/terraform'] = 'Neovim 0.13 opens a .tf file as `tf`',
  ['tsx/typescript.tsx'] = 'Neovim opens a .tsx file as `typescriptreact`',
  ['yaml/yaml.openapi'] = 'told by the `openapi:` key of an `openapi*.yaml`',
}

--- Plugins `check-startup.lua` leaves unloaded when it loads every plugin
--- nothing else did, and why: each one cannot load headless
---@type table<string, string>
M.never_load = {}

--- Files a filetype is only given beside, written ahead of its sample:
--- `ftdetect` anchors these patterns to their project
---@type table<string, string[]>
M.markers_of = {
  helm = { 'chart/Chart.yaml' },
  ['yaml.helm-values'] = { 'chart/Chart.yaml' },
}

--- Pick a file name under `root` that `vim.filetype.match` gives `filetype`
--- (and the files it is only given beside)
---@param filetype string
---@param name string Language the filetype belongs to
---@param language DyLangSpec
---@param root string
---@return string?
function M.sample_of(filetype, name, language, root)
  for _, marker in ipairs(M.markers_of[filetype] or {}) do
    local path = vim.fs.joinpath(root, marker)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile({ '' }, path)
  end
  local candidates = { 'sample.' .. filetype, 'sample.' .. name }
  if language.ext then
    table.insert(candidates, 1, 'sample.' .. language.ext)
  end
  if M.names_of[filetype] then
    table.insert(candidates, 1, M.names_of[filetype])
  end
  for _, candidate in ipairs(candidates) do
    local path = vim.fs.joinpath(root, candidate)
    if vim.filetype.match({ filename = path }) == filetype then return path end
  end
end

---@class DySample
---@field path string
---@field filetype string
---@field language string

---@class DySampleOpts
---@field all? boolean Write a file for every filetype of every language,
--- rather than one for the first filetype of each
---@field languages? string[] Languages to write files for, every one of them
--- by default

--- Write one empty file per filetype into `root`
---@param root string
---@param opts? DySampleOpts
---@return DySample[] samples
---@return string[] unmapped Filetypes no file name could be found for
---@return integer count Languages at least one file was written for
function M.generate(root, opts)
  opts = opts or {}
  local languages = require('config.languages')
  local names = opts.languages or vim.tbl_keys(languages)
  table.sort(names)
  local samples, unmapped, count = {}, {}, 0
  for _, name in ipairs(names) do
    -- `*` and `_` are what every buffer and a buffer of no language get, and
    -- neither is a language with files of its own.
    if name ~= '*' and name ~= '_' and languages[name] then
      local found = false
      for _, filetype in ipairs(languages[name].filetypes) do
        local path = M.sample_of(filetype, name, languages[name], root)
        if path then
          vim.fn.mkdir(vim.fs.dirname(path), 'p')
          vim.fn.writefile({ '' }, path)
          table.insert(
            samples,
            { path = path, filetype = filetype, language = name }
          )
          found = true
          if not opts.all then break end
        elseif opts.all then
          table.insert(unmapped, name .. '/' .. filetype)
        end
      end
      if found then
        count = count + 1
      elseif not opts.all then
        table.insert(unmapped, name)
      end
    end
  end
  return samples, unmapped, count
end

--- Run `hook` right before `plugin` is configured, or now if it already is
---@param plugin string
---@param hook fun()
function M.before_config(plugin, hook)
  local spec = require('lazy.core.config').plugins[plugin]
  if not spec then return end
  if spec._.loaded then return hook() end
  local loader = require('lazy.core.loader')
  local config = loader.config
  loader.config = function(p, ...)
    if p.name == plugin then hook() end
    return config(p, ...)
  end
end

---@class DyInstalls
---@field mason string[]
---@field parser string[]
---@field download string[]

--- Record what would have been installed instead of installing it
---@return DyInstalls installs Filled in as the plugins that own them load
function M.skip_installs()
  local installs = { mason = {}, parser = {}, download = {} }
  M.before_config('mason.nvim', function()
    -- The lazy installers of `plugins.*` all go through `MasonInstall`.
    -- Headless, the real one exits Neovim on a package it does not know.
    require('mason.api.command').MasonInstall = function(packages)
      vim.list_extend(installs.mason, packages)
    end
    -- mason's `ensure_installed` and anything else that asks a package
    -- directly. The handle it hands back is only ever listened on.
    require('mason-core.package').install = function(self)
      table.insert(installs.mason, self.name)
      local handle = {}
      function handle.on() return handle end
      function handle.once() return handle end
      return handle
    end
  end)
  M.before_config('nvim-treesitter', function()
    local treesitter = require('nvim-treesitter')
    treesitter.install = function(parsers)
      vim.list_extend(
        installs.parser,
        type(parsers) == 'table' and parsers or {}
      )
      -- Callers chain `:await` onto the task `install` hands back. The
      -- callback is never run: nothing was installed for it to set the
      -- buffer up again with.
      return { await = function() end }
    end
    -- `build` only makes sure the tree-sitter CLI and a C compiler are there
    -- to compile parsers with, and installs the CLI through Mason if not. A
    -- script that compiles nothing does not need either.
    require('util.treesitter').build = function(cb) cb() end
  end)
  -- Fetches its own `tinymist` and `websocat` release binaries on setup.
  M.before_config('typst-preview.nvim', function()
    require('typst-preview.fetch').fetch = function(_, callback)
      table.insert(installs.download, 'typst-preview')
      if callback then callback() end
    end
  end)
  -- Clones its `kulala_http` grammar and builds it with the tree-sitter CLI
  -- on setup, which throws from a scheduled callback where there is no CLI.
  M.before_config('kulala.nvim', function()
    local parser = require('kulala.config.parser')
    parser.setup = function()
      if not parser.is_up_to_date() then
        table.insert(installs.download, 'kulala_http')
      end
    end
  end)
  -- Its `build` installs the `mcp-hub` server with npm; without it, the
  -- release's `setup` reports an error rather than wait for the install.
  M.before_config('mcphub.nvim', function()
    if vim.fn.executable('mcp-hub') == 1 then return end
    table.insert(installs.download, 'mcp-hub')
    require('mcphub').setup = function() end
  end)
  -- Its `setup` loads the diff engine, which downloads the `libvscode-diff`
  -- library when the one beside it is missing or out of date.
  M.before_config('codediff.nvim', function()
    local installer = require('codediff.core.installer.libvscode_diff')
    if not installer.needs_update() then return end
    table.insert(installs.download, 'libvscode-diff')
    require('codediff').setup = function() end
  end)
  return installs
end

--- Answer every prompt as if it had been cancelled
---@return string[] prompts Filled in as prompts are asked
function M.skip_prompts()
  local prompts = {}
  local function cancel(prompt)
    table.insert(prompts, vim.trim(tostring(prompt)))
    return ''
  end
  vim.fn.input = function(opts)
    return cancel(type(opts) == 'table' and opts.prompt or opts)
  end
  vim.fn.inputsecret = cancel
  vim.ui.input = function(opts, on_confirm)
    cancel((opts or {}).prompt)
    on_confirm(nil)
  end
  return prompts
end

--- Keep Copilot's sign-in state out of the errors
---
--- `sidekick.nvim` turns Copilot's status into notifications, and an account
--- that is not signed in into an error. That is the state of the machine the
--- script runs on, not of the configuration, and only shows when the server
--- reports it before Neovim quits.
function M.quiet_sidekick()
  M.before_config('sidekick.nvim', function()
    local status = require('sidekick.status')
    local on_status = status.on_status
    status.on_status = function(err, res, ctx)
      if res and res.message and res.message:find('not signed') then
        res = vim.deepcopy(res)
        res.message = nil
      end
      return on_status(err, res, ctx)
    end
  end)
end

--- Keep the scopes of the `gh` sign-in out of the errors
---
--- octo.nvim asks `gh auth status` for the token's scopes as it sets up, and
--- reports a token without `read:project` -- or no sign-in at all, as on CI --
--- as an error. Like Copilot's sign-in, that is the state of the machine.
function M.quiet_octo()
  M.before_config('octo.nvim', function()
    local octo = require('octo')
    local setup = octo.setup
    octo.setup = function(opts)
      opts = vim.tbl_deep_extend(
        'force',
        opts or {},
        { suppress_missing_scope = { projects_v2 = true } }
      )
      return setup(opts)
    end
  end)
end

--- Keep noice from taking the script's own `vim.notify` for a rival plugin
---
--- noice checks every so often that `vim.notify` is still its own, and
--- reports an error when it is not. Here it never is: the script wraps it to
--- record errors.
function M.quiet_noice()
  M.before_config('noice.nvim', function()
    require('noice.health').checker = function() end
  end)
end

return M
