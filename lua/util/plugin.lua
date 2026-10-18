local LazyUtil = require('lazy.core.util')

local M = {}

--- Events behind `LazyFile`: the first moment a real file is in a buffer
M.lazy_file_events = { 'BufReadPost', 'BufNewFile', 'BufWritePre' }

--- Register the `LazyFile` event with lazy.nvim, for specs to load on
function M.lazy_file()
  local Event = require('lazy.core.handler.event')
  Event.mappings.LazyFile = { id = 'LazyFile', event = M.lazy_file_events }
  Event.mappings['User LazyFile'] = Event.mappings.LazyFile
end

--- Return the resolved spec of `name`, or nil when it is not part of the
--- configuration
---@param name string
---@return LazyPlugin?
function M.get_plugin(name)
  -- No spec before `lazy.setup`, and none under `nvim --clean`
  local spec = require('lazy.core.config').spec
  return spec and spec.plugins[name]
end

--- Return the install directory of `name`, with `path` under it
---@param name string
---@param path string?
---@return string?
function M.get_plugin_path(name, path)
  local plugin = M.get_plugin(name)
  path = path and '/' .. path or ''
  return plugin and (plugin.dir .. path)
end

--- Whether `name` is part of the configuration
---@param name string
---@return boolean
function M.has(name) return M.get_plugin(name) ~= nil end

--- Whether `name` has been loaded already
---@param name string
---@return boolean
function M.is_loaded(name)
  local Config = require('lazy.core.config')
  return Config.plugins[name] ~= nil and Config.plugins[name]._.loaded ~= nil
end

--- Run `fn` once `name` is loaded, right away when it already is
---@param name string
---@param fn fun(name: string)
function M.on_load(name, fn)
  if M.is_loaded(name) then
    fn(name)
  else
    vim.api.nvim_create_autocmd('User', {
      pattern = 'LazyLoad',
      callback = function(event)
        if event.data == name then
          fn(name)
          return true
        end
      end,
    })
  end
end

--- Run `fn` on lazy.nvim's `VeryLazy`
---@param fn fun()
function M.on_very_lazy(fn)
  vim.api.nvim_create_autocmd('User', {
    pattern = 'VeryLazy',
    callback = function() fn() end,
  })
end

--- Return the final `opts` of `name`, every spec merged
---@param name string
---@return table
function M.opts(name)
  local plugin = M.get_plugin(name)
  if not plugin then return {} end
  return require('lazy.core.plugin').values(plugin, 'opts', false)
end

--- Extend the list at the dotted `key` of `t` with `values`, creating the
--- tables on the way
---@generic T
---@param t table
---@param key string
---@param values T[]
---@return T[]?
function M.extend(t, key, values)
  local keys = vim.split(key, '.', { plain = true })
  for i = 1, #keys do
    local k = keys[i]
    t[k] = t[k] or {}
    if type(t[k]) ~= 'table' then return end
    t = t[k]
  end
  return vim.list_extend(t, values)
end

--- Return `list` without its repeated items, in their first order
---@generic T
---@param list T[]
---@return T[]
function M.dedup(list)
  local ret = {}
  local seen = {}
  for _, v in ipairs(list) do
    if not seen[v] then
      table.insert(ret, v)
      seen[v] = true
    end
  end
  return ret
end

--- Normalize `path` as lazy.nvim does
M.norm = LazyUtil.norm

for _, level in ipairs({ 'info', 'warn', 'error' }) do
  M[level] = function(msg, opts)
    opts = opts or {}
    opts.title = opts.title or 'DyNeo'
    return LazyUtil[level](msg, opts)
  end
end

--- Queue every `vim.notify` until something replaces it (noice), or for
--- 500 ms, then replay the queue through it
---
--- What replaces it may wrap the queue rather than drop it -- a watcher that
--- delegates to whatever `vim.notify` was -- and the replay then comes back
--- through the queue: from the replay on it passes everything straight to
--- the notifier it started with.
function M.lazy_notify()
  local notifs, replayed = {}, false
  local orig = vim.notify
  local function temp(...)
    if replayed then return orig(...) end
    table.insert(notifs, vim.F.pack_len(...))
  end
  vim.notify = temp

  local timer = assert(vim.uv.new_timer())
  local check = assert(vim.uv.new_check())

  local replay = function()
    if replayed then return end
    replayed = true
    timer:stop()
    check:stop()
    if vim.notify == temp then vim.notify = orig end
    vim.schedule(function()
      for _, notif in ipairs(notifs) do
        vim.notify(vim.F.unpack_len(notif))
      end
      notifs = {}
    end)
  end

  check:start(function()
    if vim.notify ~= temp then replay() end
  end)
  timer:start(500, 0, replay)
end

--- Path of `path` inside the Mason package `pkg`, warning when it is missing
---@param pkg string
---@param path? string
---@param opts? { warn?: boolean }
---@return string
function M.get_pkg_path(pkg, path, opts)
  pcall(require, 'mason')
  local root = vim.env.MASON or (vim.fn.stdpath('data') .. '/mason')
  opts = opts or {}
  opts.warn = opts.warn == nil and true or opts.warn
  path = path or ''
  local ret = vim.fs.normalize(root .. '/packages/' .. pkg .. '/' .. path)
  if opts.warn then
    vim.schedule(function()
      if
        not require('lazy.core.config').headless() and not vim.uv.fs_stat(ret)
      then
        M.warn(
          ('Mason package path not found for **%s**:\n- `%s`\nYou may need to force update the package.'):format(
            pkg,
            path
          )
        )
      end
    end)
  end
  return ret
end

--- `vim.keymap.set` through Snacks, skipping any mode a lazy.nvim `keys`
--- spec already claims `lhs` in, and silent unless told otherwise
function M.safe_keymap_set(mode, lhs, rhs, opts)
  local keys = require('lazy.core.handler').handlers.keys
  ---@cast keys LazyKeysHandler
  local modes = type(mode) == 'string' and { mode } or mode
  modes = vim.tbl_filter(
    function(m) return not (keys and keys.have and keys:have(lhs, m)) end,
    modes
  )
  if #modes > 0 then
    opts = opts or {}
    opts.silent = opts.silent ~= false
    if opts.remap and not vim.g.vscode then opts.remap = nil end
    Snacks.keymap.set(modes, lhs, rhs, opts)
  end
end

--- `statuscolumn` from Snacks, empty until Snacks is loaded
---@return string
function M.statuscolumn()
  return package.loaded.snacks and require('snacks.statuscolumn').get() or ''
end

--- Global values of the options plugins may set per window, taken before any
--- plugin runs, so `set_default` can tell a default from a user choice
---@type table<string, any>
M.options = {}

--- Snapshot the options `set_default` compares against
function M.snapshot_options()
  for _, option in ipairs({ 'indentexpr', 'foldmethod', 'foldexpr' }) do
    M.options[option] =
      vim.api.nvim_get_option_value(option, { scope = 'global' })
  end
end

---@type table<string, boolean>
local defaults = {}

--- Set a window- or buffer-local option to `value`, unless something other
--- than `$VIMRUNTIME` already changed it from its default
---@param option string
---@param value string|number|boolean
---@return boolean was_set
function M.set_default(option, value)
  local l = vim.api.nvim_get_option_value(option, { scope = 'local' })
  local g = M.options[option]
    or vim.api.nvim_get_option_value(option, { scope = 'global' })

  defaults[('%s=%s'):format(option, value)] = true
  local key = ('%s=%s'):format(option, l)

  if l ~= g and not defaults[key] then
    local info = vim.api.nvim_get_option_info2(option, { scope = 'local' })
    -- Only the script that set it, not every script sourced so far. A
    -- negative id is Lua, the API or a modeline: no script of `$VIMRUNTIME`.
    local scriptinfo = info.last_set_sid > 0
        and vim.fn.getscriptinfo({ sid = info.last_set_sid })
      or {}
    local by_rtp = #scriptinfo == 1
      and vim.startswith(scriptinfo[1].name, vim.fn.expand('$VIMRUNTIME'))
    if not by_rtp then return false end
  end

  vim.api.nvim_set_option_value(option, value, { scope = 'local' })
  return true
end

return M
