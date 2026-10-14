local languages_list = require('config.languages')

local M = {}

--- Filetype to the enabled language that claims it, and each language's
--- tools, worked out once. The statusline asks on every redraw, and walking
--- every filetype of every language each time adds up. Built on first use
--- rather than on `require`, so `per_machine` has had its say over
--- `DyNeo.enabled_languages` by then.
---@type table<string, string>?
local language_of
---@type table<string, string[]>
local tools_of = {}
--- Answers of the `enabled` checks, per buffer and keyed by the buffer's name
--- when asked: a check may walk up the file system, and a rename or `:saveas`
--- is the only thing that can change its answer.
---@type table<integer, { name: string, answers: table<string, boolean> }>
local enabled_of = {}

--- Every language name, sorted: `pairs` order differs between sessions, and
--- what is built from the list must not
---@return string[]
M.names = function()
  local names = vim.tbl_keys(languages_list)
  table.sort(names)
  return names
end

--- Return whether `server` would attach to `bufnr`, as its spec decides
---@param server DyLspSpec
---@param bufnr integer
---@return boolean
local function is_enabled(server, bufnr)
  if not server.enabled then return true end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local cached = enabled_of[bufnr]
  if not cached or cached.name ~= name then
    cached = { name = name, answers = {} }
    enabled_of[bufnr] = cached
  end
  if cached.answers[server[1]] == nil then
    cached.answers[server[1]] = server.enabled(bufnr) and true or false
  end
  return cached.answers[server[1]]
end

--- Return language from filetype
---@param filetype string Filetype of buffer
---@return string?
M.get_language_from_filetype = function(filetype)
  if not language_of then
    language_of = {}
    for _, name in ipairs(DyNeo.enabled_languages) do
      for _, ft in ipairs((languages_list[name] or {}).filetypes or {}) do
        language_of[ft] = name
      end
    end
  end
  return language_of[filetype]
end

--- Return the entries of `field` for `language_name`, after the ones every
--- filetype gets from `*`
---@param language_name string
---@param field string
---@return table
local function with_common(language_name, field)
  return vim.list_extend(
    vim.deepcopy(languages_list['*'][field] or {}),
    languages_list[language_name][field] or {}
  )
end

--- Return list command of tools for formatters, linters and other actions
---@param filetype string Filetype of buffer
---@return string[]
M.get_tools_by_filetype = function(filetype)
  local language_name = M.get_language_from_filetype(filetype) or '_'
  if tools_of[language_name] then return tools_of[language_name] end

  local result = {}
  for _, field in ipairs({ 'formatters', 'linters' }) do
    for _, tool in ipairs(with_common(language_name, field)) do
      if type(tool) == 'string' then
        table.insert(result, tool)
      else
        table.insert(result, tool.command or tool[1])
      end
    end
  end
  for _, tool in ipairs(with_common(language_name, 'null_ls')) do
    table.insert(result, tool.command)
  end

  tools_of[language_name] = require('util.plugin').dedup(result)
  return tools_of[language_name]
end

--- Return the Mason package name of a tool spec
---
--- A tool's Mason package, the executable it runs and the name it carries
--- inside `conform`/`nvim-lint` are three different things. An explicit
--- `mason.package` is the only one that is always the package, so it wins;
--- `command` comes next, for the tools that expose several entries out of one
--- binary (`ruff_fix`, `ruff_format`, ...).
---@param tool string|table Tool spec from `config.languages`
---@return string
M.get_mason_package = function(tool)
  if type(tool) == 'string' then return tool end
  return (tool.mason and tool.mason.package) or tool.command or tool[1]
end

--- Return the Mason package of the tool of `filetype` that runs `command`
---
--- The reverse of `get_tools_by_filetype`, which hands out commands: what a
--- missing command is installed from (`forge` -> `foundry`).
---@param filetype string Filetype of buffer
---@param command string
---@return string?
M.get_mason_package_by_command = function(filetype, command)
  local language_name = M.get_language_from_filetype(filetype) or '_'
  for _, field in ipairs({ 'formatters', 'linters', 'null_ls' }) do
    for _, tool in ipairs(with_common(language_name, field)) do
      local runs = type(tool) == 'string' and tool or (tool.command or tool[1])
      if runs == command then return M.get_mason_package(tool) end
    end
  end
end

--- Whether the command a tool spec names can run here
---
--- `lua` stands for a tool that runs inside Neovim itself, so it is there
--- whether or not the machine has a Lua interpreter of its own.
---@param command string
---@return boolean
M.is_available = function(command)
  return command == 'lua' or vim.fn.executable(command) == 1
end

--- Return list of LSP servers for filetype
---
--- A server whose spec carries an `enabled` check is left out of a buffer it
--- turns down, the same way `plugins.lsp.server` keeps it from attaching.
---
--- A server configured without `filetypes` (Copilot) starts for any buffer
--- and decides for itself, in its `root_dir`, whether to attach. Its absence
--- is then no sign of trouble, so it comes back in the second list: shown
--- when attached, not expected otherwise.
---@param filetype string Filetype of buffer
---@param bufnr? integer Buffer the check is asked about, current by default
---@return string[] expected Servers that should attach to the buffer
---@return string[] optional Servers that attach to any filetype if they choose
M.get_lsp_servers_by_filetype = function(filetype, bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local result = {}
  local optional = {}
  local language_name = M.get_language_from_filetype(filetype) or '_'

  for _, server in ipairs(with_common(language_name, 'lsp_servers')) do
    local server_name = server --[[@as string]]
    if type(server) == 'table' then
      if not is_enabled(server, bufnr) then goto continue end
      server_name = server[1]
    end
    local lsp_config = vim.lsp.config[server_name]
    if lsp_config == nil then goto continue end
    if lsp_config.filetypes == nil then
      table.insert(optional, server_name)
    elseif
      lsp_config.filetypes == '*'
      or vim.list_contains(lsp_config.filetypes, filetype)
    then
      table.insert(result, server_name)
    end
    ::continue::
  end

  return require('util.plugin').dedup(result),
    require('util.plugin').dedup(optional)
end

return M
