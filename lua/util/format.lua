local Plugin = require('util.plugin')

--- Formatters registered by priority. Of the primary ones, only the first
--- with a source for the buffer runs. `require('util.format')()` formats.
---@class util.format
---@overload fun(opts?: { force?: boolean, buf?: number })
local M = setmetatable({}, {
  __call = function(m, ...) return m.format(...) end,
})

---@class Formatter
---@field name string
---@field primary? boolean
---@field format fun(bufnr: number)
---@field sources fun(bufnr: number): string[]
---@field priority number

---@type Formatter[]
M.formatters = {}

---@param formatter Formatter
function M.register(formatter)
  M.formatters[#M.formatters + 1] = formatter
  table.sort(M.formatters, function(a, b) return a.priority > b.priority end)
end

--- `formatexpr` going through conform when it is installed
function M.formatexpr()
  -- Formatters load the project's own config and plugins (prettier, eslint),
  -- so a held directory is left to Vim's own `gq`, which a `1` asks for
  if require('util.untrusted').held(0) then return 1 end
  if Plugin.has('conform.nvim') then return require('conform').formatexpr() end
  return vim.lsp.formatexpr({ timeout_ms = 3000 })
end

---@param buf? number
---@return (Formatter|{ active: boolean, resolved: string[] })[]
function M.resolve(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local have_primary = false
  return vim.tbl_map(function(formatter)
    local sources = formatter.sources(buf)
    local active = #sources > 0 and (not formatter.primary or not have_primary)
    have_primary = have_primary or (active and formatter.primary) or false
    return setmetatable(
      { active = active, resolved = sources },
      { __index = formatter }
    )
  end, M.formatters)
end

--- Show whether autoformat is on, and which formatters would run
---@param buf? number
function M.info(buf)
  buf = buf or vim.api.nvim_get_current_buf()
  local gaf = vim.g.autoformat == nil or vim.g.autoformat
  local baf = vim.b[buf].autoformat
  local enabled = M.enabled(buf)
  local lines = {
    '# Status',
    ('- [%s] global **%s**'):format(
      gaf and 'x' or ' ',
      gaf and 'enabled' or 'disabled'
    ),
    ('- [%s] buffer **%s**'):format(
      enabled and 'x' or ' ',
      baf == nil and 'inherit' or baf and 'enabled' or 'disabled'
    ),
  }
  local have = false
  for _, formatter in ipairs(M.resolve(buf)) do
    if #formatter.resolved > 0 then
      have = true
      lines[#lines + 1] = '\n# '
        .. formatter.name
        .. (formatter.active and ' ***(active)***' or '')
      for _, line in ipairs(formatter.resolved) do
        lines[#lines + 1] = ('- [%s] **%s**'):format(
          formatter.active and 'x' or ' ',
          line
        )
      end
    end
  end
  if not have then
    lines[#lines + 1] = '\n***No formatters available for this buffer.***'
  end
  Plugin[enabled and 'info' or 'warn'](table.concat(lines, '\n'), {
    title = require('util.notify').title(
      'Format (' .. (enabled and 'enabled' or 'disabled') .. ')'
    ),
  })
end

--- Whether to format `buf` on save: its own `b:autoformat`, else
--- `g:autoformat`, else yes
---@param buf? number
---@return boolean
function M.enabled(buf)
  buf = (buf == nil or buf == 0) and vim.api.nvim_get_current_buf() or buf
  local baf = vim.b[buf].autoformat
  if baf ~= nil then return baf end
  local gaf = vim.g.autoformat
  return gaf == nil or gaf
end

---@param buf? boolean
function M.toggle(buf) M.enable(not M.enabled(), buf) end

---@param enable? boolean
---@param buf? boolean
function M.enable(enable, buf)
  if enable == nil then enable = true end
  if buf then
    vim.b.autoformat = enable
  else
    vim.g.autoformat = enable
    vim.b.autoformat = nil
  end
  M.info()
end

---@param opts? { force?: boolean, buf?: number }
function M.format(opts)
  opts = opts or {}
  local buf = opts.buf or vim.api.nvim_get_current_buf()
  if not (opts.force or M.enabled(buf)) then return end
  -- Formatters load the project's own config and plugins (prettier, eslint),
  -- so nothing formats a buffer under a directory still held untrusted. No
  -- warning either, as a save there is meant to leave the file as it is.
  if require('util.untrusted').held(buf) then return end

  local done = false
  for _, formatter in ipairs(M.resolve(buf)) do
    if formatter.active then
      done = true
      require('lazy.core.util').try(
        function() return formatter.format(buf) end,
        { msg = 'Formatter `' .. formatter.name .. '` failed' }
      )
    end
  end

  if not done and opts.force then Plugin.warn('No formatter available') end
end

--- Format on save, and add `:DyFormat` and `:DyFormatInfo`
function M.setup()
  vim.api.nvim_create_autocmd('BufWritePre', {
    group = vim.api.nvim_create_augroup('dyneo_format', {}),
    callback = function(event) M.format({ buf = event.buf }) end,
  })
  vim.api.nvim_create_user_command(
    'DyFormat',
    function() M.format({ force = true }) end,
    { desc = 'Format the buffer' }
  )
  vim.api.nvim_create_user_command(
    'DyFormatInfo',
    function() M.info() end,
    { desc = 'Show info about the formatters for the current buffer' }
  )
end

--- Snacks toggle for autoformat, globally or for the buffer
---@param buf? boolean
function M.snacks_toggle(buf)
  return Snacks.toggle({
    name = 'Auto Format (' .. (buf and 'Buffer' or 'Global') .. ')',
    get = function()
      if not buf then return vim.g.autoformat == nil or vim.g.autoformat end
      return M.enabled()
    end,
    set = function(state) M.enable(state, buf) end,
  })
end

return M
