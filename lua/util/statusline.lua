--- Language servers and tools of a buffer, for the statusline
---
--- Spelling out every server and tool the filetype expects crowds the
--- statusline as soon as a language brings more than a couple. So it only
--- counts how many are up, and the full list, with the state of each
--- candidate and what can be done about it, lives in a picker opened by a
--- click on the count or by a key.

local languages = require('util.languages')

local M = {}

local notify = require('util.notify').titled('Statusline')

--- Commands that run inside Neovim (`lua`) or come with every system, the
--- ones `config.languages` marks `mason.enabled = false`: nothing installs
--- them, so they are neither counted nor listed
local ignored_tools = { 'lua', 'git', 'curl', 'sed' }

--- What the statusline asks on every redraw, kept until an event can change
--- the answer: the server count of each buffer until a client attaches or
--- detaches or the filetype changes, and whether each tool is on `$PATH`
--- until Mason installs or removes a package or Neovim regains the focus
--- (a tool installed from another terminal).
---@type table<integer, string>
local lsp_text = {}
---@type table<string, boolean>
local executable = {}

---@class DyLspCandidate
---@field name string
---@field client? vim.lsp.Client The client attached to the buffer, if any
---@field expected boolean Whether the filetype asks for it

---@class DyToolCandidate
---@field name string The command the tool runs
---@field package? string The Mason package that installs it
---@field path? string Where the executable is, if it is on `$PATH`

--- Return the servers expected for `bufnr`, then the ones attached anyway
---
--- Servers of any filetype (Copilot) only come in when attached, as extras:
--- their absence is no sign of trouble.
---@param bufnr integer
---@return DyLspCandidate[]
function M.lsp_candidates(bufnr)
  local attached = {}
  for _, client in ipairs(vim.lsp.get_clients({ bufnr = bufnr })) do
    attached[client.name] = client
  end

  local result = {}
  local expected =
    languages.get_lsp_servers_by_filetype(vim.bo[bufnr].filetype, bufnr)
  for _, name in ipairs(expected) do
    table.insert(
      result,
      { name = name, client = attached[name], expected = true }
    )
    attached[name] = nil
  end

  local extras = vim.tbl_keys(attached)
  table.sort(extras)
  for _, name in ipairs(extras) do
    table.insert(
      result,
      { name = name, client = attached[name], expected = false }
    )
  end
  return result
end

--- Return the formatters, linters and other tools of `filetype`
---@param filetype string
---@return DyToolCandidate[]
function M.tool_candidates(filetype)
  local result = {}
  for _, tool in ipairs(languages.get_tools_by_filetype(filetype)) do
    if not vim.list_contains(ignored_tools, tool) then
      local path = vim.fn.exepath(tool)
      table.insert(result, {
        name = tool,
        package = languages.get_mason_package_by_command(filetype, tool),
        path = path ~= '' and path or nil,
      })
    end
  end
  return result
end

--- Return `icon` followed by `up` out of `total`, and a `!` when some are down
---@param icon string
---@param up integer
---@param total integer
---@return string
local function count(icon, up, total)
  if total == 0 then return vim.trim(icon) end
  if up == total then return icon .. total end
  return ('%s%d/%d!'):format(icon, up, total)
end

--- Return the statusline text of the servers expected for the current buffer
---
--- Extras are left out of the count: sidekick's icon already shows whether
--- Copilot is on, busy, or turned down by a sensitive buffer.
---@param icon string
---@return string
function M.lsp_status(icon)
  local bufnr = vim.api.nvim_get_current_buf()
  if lsp_text[bufnr] then return lsp_text[bufnr] end
  local up, total = 0, 0
  for _, candidate in ipairs(M.lsp_candidates(bufnr)) do
    if candidate.expected then
      total = total + 1
      if candidate.client then up = up + 1 end
    end
  end
  lsp_text[bufnr] = count(icon, up, total)
  return lsp_text[bufnr]
end

--- Return the statusline text of the tools of the current buffer
---
--- Checked with `executable()` instead of going through `tool_candidates`,
--- which resolves each path, and each answer kept: the statusline asks on
--- every redraw.
---@param icon string
---@return string
function M.tools_status(icon)
  local up, total = 0, 0
  for _, tool in ipairs(languages.get_tools_by_filetype(vim.bo.filetype)) do
    if not vim.list_contains(ignored_tools, tool) then
      total = total + 1
      if executable[tool] == nil then
        executable[tool] = vim.fn.executable(tool) == 1
      end
      if executable[tool] then up = up + 1 end
    end
  end
  return count(icon, up, total)
end

--- Drop what the statusline kept, for `bufnr` only when given
---@param bufnr? integer
function M.forget(bufnr)
  if bufnr then
    lsp_text[bufnr] = nil
  else
    lsp_text, executable = {}, {}
  end
end

--- Forget what the statusline kept whenever its answer may have changed
function M.setup()
  local group = vim.api.nvim_create_augroup('dyneo_statusline', {})
  vim.api.nvim_create_autocmd({ 'LspAttach', 'FileType', 'BufFilePost' }, {
    group = group,
    callback = function(event) M.forget(event.buf) end,
  })
  vim.api.nvim_create_autocmd('LspDetach', {
    group = group,
    -- The detaching client is still listed while the event runs
    callback = function(event)
      M.forget(event.buf)
      vim.schedule(function() M.forget(event.buf) end)
    end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(event) M.forget(event.buf) end,
  })
  vim.api.nvim_create_autocmd('FocusGained', {
    group = group,
    callback = function() executable = {} end,
  })
  require('util.plugin').on_load('mason.nvim', function()
    local registry = require('mason-registry')
    for _, event in ipairs({
      'package:install:success',
      'package:uninstall:success',
    }) do
      registry:on(event, vim.schedule_wrap(function() executable = {} end))
    end
  end)
end

local function refresh()
  local ok, lualine = pcall(require, 'lualine')
  if ok then lualine.refresh({ place = { 'statusline' } }) end
end

--- Install the Mason package `package`, if the registry knows it
---@param name string What the package is installed for
---@param package? string
local function mason_install(name, package)
  local ok, registry = pcall(require, 'mason-registry')
  if not (ok and package and registry.has_package(package)) then
    return notify(
      ('No Mason package for `%s`, install it by hand'):format(name),
      vim.log.levels.WARN
    )
  end
  vim.cmd.MasonInstall(package)
end

--- Return the Mason package of the server `name`
---@param name string
---@return string?
local function lsp_package(name)
  local ok, mason_lspconfig = pcall(require, 'mason-lspconfig')
  if not ok then return nil end
  return mason_lspconfig.get_mappings().lspconfig_to_package[name]
end

--- Return the command of a client or of a server config, as text
---@param cmd? string[]|function
---@return string
local function cmd_text(cmd)
  if type(cmd) == 'table' then return table.concat(cmd, ' ') end
  if type(cmd) == 'function' then return '(function)' end
  return '(none)'
end

--- Return whether the executable of a server config is on `$PATH`
---@param config? vim.lsp.Config
---@return boolean? installed `nil` when the command is not a plain list
local function is_installed(config)
  local cmd = config and config.cmd
  if type(cmd) ~= 'table' then return nil end
  return vim.fn.executable(cmd[1]) == 1
end

--- Return the one-line state of a server candidate, and its highlight
---@param candidate DyLspCandidate
---@return string sign, string hl, string detail
local function lsp_state(candidate)
  local client = candidate.client
  if client then
    local sign = candidate.expected and '● ' or '○ '
    local root = client.root_dir
    return sign,
      'DiagnosticOk',
      root and vim.fn.fnamemodify(root, ':~') or 'single file'
  end
  if is_installed(vim.lsp.config[candidate.name]) == false then
    return '! ', 'DiagnosticError', 'not installed'
  end
  return '! ', 'DiagnosticWarn', 'not attached'
end

---@param candidate DyLspCandidate
---@return string
local function lsp_preview(candidate)
  local client = candidate.client
  local config = client and client.config or vim.lsp.config[candidate.name]
  local installed = is_installed(config)
  local lines = {
    '# ' .. candidate.name,
    '',
    '- State: '
      .. (client and ('attached, id ' .. client.id) or 'not attached'),
    '- Expected: ' .. (candidate.expected and 'yes' or 'no, attached anyway'),
    '- Enabled: ' .. (vim.lsp.is_enabled(candidate.name) and 'yes' or 'no'),
    '- Installed: '
      .. (installed == nil and 'unknown' or installed and 'yes' or 'no'),
    '- Command: `' .. cmd_text(config and config.cmd) .. '`',
  }
  if client then
    table.insert(
      lines,
      '- Root: `' .. (client.root_dir or 'single file') .. '`'
    )
  end
  local filetypes = config and config.filetypes
  table.insert(
    lines,
    '- Filetypes: ' .. (filetypes and table.concat(filetypes, ', ') or 'any')
  )
  return table.concat(lines, '\n')
end

---@class DyCandidatePicker
---@field title string
---@field items { name: string }[]
---@field width integer Width of the widest name, to line the details up
---@field format fun(item: table): (string, string, string) Sign, its highlight, detail
---@field confirm fun(item: table)
---@field actions? table<string, function>
---@field keys? table<string, table>

--- Open candidates in a picker, each with a sign, its name and one detail
---@param opts DyCandidatePicker
local function pick(opts)
  Snacks.picker.pick({
    title = opts.title,
    items = opts.items,
    format = function(item)
      local sign, hl, detail = opts.format(item)
      return {
        { sign, hl },
        {
          item.name .. (' '):rep(opts.width - vim.api.nvim_strwidth(item.name)),
          'SnacksPickerLabel',
        },
        { '  ' },
        { detail, 'SnacksPickerComment' },
      }
    end,
    preview = 'preview',
    layout = { preset = 'default' },
    confirm = function(picker, item)
      picker:close()
      if item then opts.confirm(item) end
      vim.schedule(refresh)
    end,
    actions = opts.actions,
    win = { input = { keys = opts.keys or {} } },
  })
end

---@param items { name: string }[]
---@return integer
local function name_width(items)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, vim.api.nvim_strwidth(item.name))
  end
  return width
end

--- Pick among the servers of `bufnr`: `<CR>` restarts an attached one, and
--- starts a missing one or installs it when its command is not found;
--- `<M-s>` stops one
---@param bufnr? integer
function M.pick_lsp(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local candidates = M.lsp_candidates(bufnr)
  if #candidates == 0 then
    return notify('No language server for this buffer', vim.log.levels.INFO)
  end
  -- Worked out here rather than kept as the client: the picker copies its
  -- items, and a client holds userdata that cannot be copied.
  local items = vim.tbl_map(function(candidate)
    local sign, hl, detail = lsp_state(candidate)
    return {
      name = candidate.name,
      text = candidate.name,
      attached = candidate.client ~= nil,
      sign = sign,
      hl = hl,
      detail = detail,
      preview = { text = lsp_preview(candidate), ft = 'markdown' },
    }
  end, candidates)
  pick({
    title = 'Language servers',
    items = items,
    width = name_width(items),
    format = function(item) return item.sign, item.hl, item.detail end,
    confirm = function(item)
      if item.attached then
        return vim.cmd.lsp({ args = { 'restart', item.name } })
      end
      if is_installed(vim.lsp.config[item.name]) == false then
        return mason_install(item.name, lsp_package(item.name))
      end
      vim.cmd.lsp({ args = { 'enable', item.name } })
    end,
    actions = {
      lsp_stop = function(picker, item)
        picker:close()
        if not (item and item.attached) then return end
        vim.cmd.lsp({ args = { 'stop', item.name } })
        vim.schedule(refresh)
      end,
    },
    keys = {
      ['<M-s>'] = { 'lsp_stop', mode = { 'n', 'i' }, desc = 'Stop server' },
    },
  })
end

--- Pick among the tools of `bufnr`: `<CR>` installs a missing one with
--- Mason, and opens Mason on an installed one
---@param bufnr? integer
function M.pick_tools(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local candidates = M.tool_candidates(vim.bo[bufnr].filetype)
  if #candidates == 0 then
    return notify('No formatter or linter for this buffer', vim.log.levels.INFO)
  end
  local items = vim.tbl_map(
    function(candidate)
      return vim.tbl_extend('force', candidate, {
        text = candidate.name,
        preview = {
          text = table.concat({
            '# ' .. candidate.name,
            '',
            '- Installed: ' .. (candidate.path and 'yes' or 'no'),
            '- Path: `' .. (candidate.path or 'not on $PATH') .. '`',
          }, '\n'),
          ft = 'markdown',
        },
      })
    end,
    candidates
  )
  pick({
    title = 'Formatters and linters',
    items = items,
    width = name_width(items),
    format = function(item)
      if item.path then return '● ', 'DiagnosticOk', item.path end
      return '! ', 'DiagnosticError', 'not installed'
    end,
    confirm = function(item)
      if item.path then return vim.cmd.Mason() end
      mason_install(item.name, item.package or item.name)
    end,
  })
end

return M
