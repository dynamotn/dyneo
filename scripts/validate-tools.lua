-- Check that every tool named in `config.languages` actually exists.
--
-- A tool carries up to three different names: the module conform or nvim-lint
-- knows it by, the binary it runs, and the Mason package that installs it.
-- When they drift apart nothing breaks loudly -- the linter simply never runs,
-- or Mason is asked for a package that is not there -- so they are checked
-- here instead.
--
--   nvim --clean --headless -l scripts/validate-tools.lua
--
-- Exits non-zero, and prints one line per problem, when something is off.
-- It also exits non-zero when nothing could be checked at all (no plugins
-- and no Mason registry under `stdpath('data')`, as on a fresh clone or a
-- new `NVIM_APPNAME`): a check that cannot run must not read as one that
-- passed. `VALIDATE_TOOLS_ALLOW_SKIP=1` lets that case pass, for a machine
-- that knowingly has none of them.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local data = vim.fn.stdpath('data')
vim.opt.runtimepath:prepend(root)
vim.opt.runtimepath:append(data .. '/lazy/conform.nvim')
vim.opt.runtimepath:append(data .. '/lazy/nvim-lint')
vim.opt.runtimepath:append(data .. '/lazy/nvim-lspconfig')
-- mason-nvim-dap's name-to-package table leans on mason's own library
vim.opt.runtimepath:append(data .. '/lazy/mason.nvim')
vim.opt.runtimepath:append(data .. '/lazy/mason-nvim-dap.nvim')

local registry = data
  .. '/mason/registries/github/mason-org/mason-registry/registry.json'

-- Every check reads its answer out of `stdpath('data')`. On a machine that has
-- never run this configuration -- a fresh clone, a container, CI -- none of it
-- is there, and a tool that cannot be looked up is not the same thing as a
-- tool that is named wrong. So each group runs only when what it reads from is
-- present, and whatever had to be passed over is said out loud at the end.
local checkable = {
  formatters = vim.fn.isdirectory(data .. '/lazy/conform.nvim') == 1,
  linters = vim.fn.isdirectory(data .. '/lazy/nvim-lint') == 1,
  lsp = vim.fn.isdirectory(data .. '/lazy/nvim-lspconfig') == 1,
  dap = vim.fn.isdirectory(data .. '/lazy/mason-nvim-dap.nvim') == 1
    and vim.fn.isdirectory(data .. '/lazy/mason.nvim') == 1,
  mason = vim.fn.filereadable(registry) == 1,
}

---@type table<string, string> What each group needs, for the message
local needs = {
  formatters = 'conform.nvim',
  linters = 'nvim-lint',
  lsp = 'nvim-lspconfig',
  dap = 'mason-nvim-dap.nvim and mason.nvim',
  mason = 'the Mason registry',
}

--- Tool names the repo's own Mason registry adds
---
--- Read straight off this tree instead of through `require`: the module picks
--- its folder with `stdpath('config')`, which is the configuration in use and
--- not necessarily the one being checked. A package handed to dytoy
--- (`dytoy:<tool>`) counts as soon as its file is here: whether dytoy knows
--- that tool is not checked.
---@return table<string, true>
local function own_registry()
  local names = {}
  local files =
    vim.fn.glob(root .. '/lua/tools/mason-registry/*.lua', true, true)
  for _, file in ipairs(files) do
    local tool = vim.fn.fnamemodify(file, ':t:r')
    if tool ~= 'init' then names[tool] = true end
  end
  return names
end

---@return table<string, true>
local function mason_packages()
  local packages = own_registry()
  if checkable.mason then
    for _, package in
      ipairs(vim.json.decode(table.concat(vim.fn.readfile(registry), '\n')))
    do
      packages[package.name] = true
    end
  end
  return packages
end

local packages = mason_packages()
local languages = require('config.languages')
local dap_util = require('util.dap')
local names = vim.tbl_keys(languages)
table.sort(names)

local problems = {}
---@param language string
---@param kind string
---@param tool string
---@param message string
local function report(language, kind, tool, message)
  table.insert(
    problems,
    string.format('%-14s %-10s %-24s %s', language, kind, tool, message)
  )
end

-- Some formatters conform does not ship are defined by the config itself.
-- Rather than keep a second list of them here, run the conform spec the way
-- lazy.nvim would and ask it what it defined.
---@return table<string, true>
local function config_formatters()
  local defined = {}
  local ok, spec = pcall(dofile, root .. '/lua/plugins/executor/formatting.lua')
  if not ok then return defined end
  package.loaded['util.plugin'] = { on_load = function() end }
  local opts = { formatters = {}, formatters_by_ft = {} }
  local called, returned = pcall(spec[1].opts, nil, opts)
  if called then
    -- The spec may hand back a new table rather than fill this one
    opts = returned or opts
    for formatter in pairs(opts.formatters) do
      defined[formatter] = true
    end
  end
  return defined
end

local local_formatters = config_formatters()

local modules = {
  formatters = 'conform.formatters.',
  linters = 'lint.linters.',
}

for _, name in ipairs(names) do
  local language = languages[name]
  for kind, module in pairs(modules) do
    for _, tool in ipairs(language[kind] or {}) do
      local tool_name = type(tool) == 'string' and tool or tool[1]
      local mason = type(tool) == 'table' and tool.mason or nil
      if
        checkable[kind]
        and not local_formatters[tool_name]
        and not pcall(require, module .. tool_name)
      then
        report(name, kind, tool_name, 'no such ' .. kind:sub(1, -2))
      end
      if checkable.mason and not (mason and mason.enabled == false) then
        local package = (mason and mason.package)
          or (type(tool) == 'table' and tool.command)
          or tool_name
        if not packages[package] then
          report(
            name,
            kind,
            tool_name,
            string.format('no Mason package `%s`', package)
          )
        end
      end
    end
  end

  for _, server in ipairs(language.lsp_servers or {}) do
    local server_name = type(server) == 'string' and server or server[1]
    -- a server the repo configures itself lives in `lsp/`, or in `after/lsp/`
    -- when it overrides nvim-lspconfig
    if
      checkable.lsp
      and vim.fn.filereadable(string.format('%s/lsp/%s.lua', root, server_name)) == 0
      and vim.fn.filereadable(
        string.format('%s/after/lsp/%s.lua', root, server_name)
      ) == 0
      and #vim.api.nvim_get_runtime_file(
          'lsp/' .. server_name .. '.lua',
          false
        )
        == 0
    then
      report(name, 'lsp', server_name, 'no such server config')
    end
  end

  -- an adapter is installed through the package mason-nvim-dap maps its name
  -- to, or through the one the entry names when there is no such mapping
  for _, spec in ipairs(language.dap or {}) do
    local adapter = dap_util.name(spec)
    local package = dap_util.package(spec)
    if not package then
      if checkable.dap then
        report(name, 'dap', adapter, 'not mapped to a Mason package')
      end
    elseif checkable.mason and not packages[package] then
      report(
        name,
        'dap',
        adapter,
        string.format('no Mason package `%s`', package)
      )
    end
  end
end

local skipped = {}
for group, ok in pairs(checkable) do
  if not ok then table.insert(skipped, needs[group]) end
end
table.sort(skipped)

for _, problem in ipairs(problems) do
  print(problem)
end

local nothing = #skipped == vim.tbl_count(checkable)
if #skipped > 0 then
  print(
    string.format(
      'config.languages: %s, so nothing that needs %s was checked',
      nothing and 'nothing to check against' or 'partial check',
      table.concat(skipped, ', ')
    )
  )
elseif vim.tbl_isempty(problems) then
  print('config.languages: every tool resolves')
end
local skip_allowed = vim.env.VALIDATE_TOOLS_ALLOW_SKIP == '1'
if nothing and not skip_allowed then
  print(
    'config.languages: install the plugins (or set'
      .. ' VALIDATE_TOOLS_ALLOW_SKIP=1) to pass without a check'
  )
end

os.exit(
  (vim.tbl_isempty(problems) and (skip_allowed or not nothing)) and 0 or 1
)
