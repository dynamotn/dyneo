-- Write `doc/dyneo-keymaps.txt`: every mapping this configuration
-- sets, read off the configuration as it loads rather than kept by hand.
--
-- Loaded with `--cmd` by `keymaps-doc.sh`, ahead of `init.lua`, so it can
-- watch `vim.keymap.set` from the first mapping on. Four sources are read:
--
-- - the `keys` of every plugin spec, through lazy.nvim's own resolution, so
--   a later spec overriding a key is what shows;
-- - the `keys` of the language servers, from the merged nvim-lspconfig
--   options, for the buffers a server attaches to;
-- - every other `vim.keymap.set` made from this tree: `config.keymaps`, what
--   plugin `opts` and `config` functions map themselves, and what an
--   `on_attach` maps in the buffer it attaches to;
-- - what the tools of `lua/tools` map in the buffers their `plugin/` shim
--   attaches them to on `FileType`.
--
-- Groups come from which-key's `spec`. Mappings a plugin makes on its own,
-- with no `keys` entry here, are left to `:help` of that plugin.
--
-- It also fails on two mistakes nothing else catches, so the hook stops the
-- commit that brings one in:
--
-- - a dead mapping: `util.plugin.safe_keymap_set` leaves out a key some
--   plugin's `keys` already takes, so `config.keymaps` setting it does
--   nothing at all;
-- - a conflict: the same key in the same mode, everywhere, given two
--   different meanings by two different places, where whichever comes last
--   silently wins.

-- The tree as Lua names its files: `stdpath('config')` is the link
-- `keymaps-doc.sh` points at it
local root = vim.uv.fs_realpath(vim.fn.stdpath('config')) --[[@as string]]
local output = vim.fs.joinpath(root, 'doc', 'dyneo-keymaps.txt')
-- Modules may be named by the link or by the tree it points at, depending on
-- which loader found them
local roots = { root, vim.fs.normalize(vim.fn.stdpath('config')) }

--- `source` as a path inside this tree, or nil for a file outside it
---@param source string
---@return string?
local function relative(source)
  for _, prefix in ipairs(roots) do
    if source:sub(1, #prefix + 1) == prefix .. '/' then
      return source:sub(#prefix + 2)
    end
  end
end

--- Mappings `config.keymaps` sets in vain, see the top of this file
---@type string[]
local dead = {}

-- Every plugin, whatever this machine turns off
package.preload['per_machine'] = function() DyNeo.used_full_plugins = true end
-- ... without installing the ones it has not got: their specs are read,
-- never loaded. `config.lazy` asks for `util.plugin` once lazy.nvim is on
-- the runtimepath and before `setup`, which is the moment to step in.
package.preload['util.plugin'] = function()
  package.preload['util.plugin'] = nil
  local lazy = require('lazy')
  local setup = lazy.setup
  lazy.setup = function(spec, opts)
    -- `config.lazy` hands everything over as one table holding `spec`,
    -- which lazy.nvim then reads as the options: the overrides go there
    if type(spec) == 'table' and spec.spec then
      spec, opts = nil, spec
    end
    opts = vim.tbl_deep_extend('force', opts or {}, {
      install = { missing = false },
      checker = { enabled = false },
      change_detection = { enabled = false },
    })
    if spec ~= nil then opts.spec = spec end
    -- A spec turned on by a binary (`enabled` or `cond` asking
    -- `executable`: mcphub for npm, flutter-tools for dart, R.nvim for R) or
    -- by the Neovim it runs on (`has('nvim-0.13')`: ci.nvim) is read as on a
    -- machine that has them all, so the file does not change with the
    -- machine or the channel it is written on. Only while the specs resolve:
    -- what runs afterwards sees the machine as it is.
    local LazyPlugin = require('lazy.core.plugin')
    local load = LazyPlugin.load
    LazyPlugin.load = function(...)
      local executable, has = vim.fn.executable, vim.fn.has
      vim.fn.executable = function() return 1 end
      vim.fn.has = function(feature)
        if feature:match('^nvim%-') then return 1 end
        return has(feature)
      end
      local ok, err = pcall(load, ...)
      vim.fn.executable, vim.fn.has = executable, has
      if not ok then error(err, 0) end
    end
    return setup(opts)
  end
  local Plugin =
    assert(loadfile(vim.fs.joinpath(root, 'lua/util/plugin.lua')))()
  -- What it leaves out, as dead mappings
  local safe_keymap_set = Plugin.safe_keymap_set
  Plugin.safe_keymap_set = function(mode, lhs, rhs, opts)
    local keys = require('lazy.core.handler').handlers.keys
    for _, m in ipairs(type(mode) == 'table' and mode or { mode }) do
      if keys and keys.have and keys:have(lhs, m) then
        local info = debug.getinfo(2, 'Sl')
        table.insert(
          dead,
          ("%s %s (%s) at %s:%d: a plugin's `keys` takes it"):format(
            m,
            lhs,
            (opts or {}).desc or 'no description',
            relative(info.source:gsub('^@', '')) or info.short_src,
            info.currentline
          )
        )
      end
    end
    return safe_keymap_set(mode, lhs, rhs, opts)
  end
  return Plugin
end

---@class DyKeymap
---@field lhs string
---@field modes string[]
---@field desc string
---@field scope string Where it applies: '' for everywhere
---@field from string The file, or the plugin spec, it comes from

---@type DyKeymap[]
local maps = {}
--- Groups named by a `keys` entry with no right-hand side, `+ai` style
---@type table<string, string>
local key_groups = {}

--- `<Leader>` and friends written one way, so the same key compares equal
---@param lhs string
---@return string
local function normalize(lhs)
  lhs = lhs
    :gsub('<[Ll]eader>', '<leader>')
    :gsub('<[Ll]ocal[Ll]eader>', '<localleader>')
  return (lhs:gsub('^ ', '<leader>'))
end

---@param modes string|string[]|nil
---@return string[]
local function mode_list(modes)
  modes = type(modes) == 'table' and modes or { modes or 'n' }
  local ret = vim.deepcopy(modes)
  table.sort(ret)
  return ret
end

--- The filetype whose `ftplugin/` file is being sourced, for the scope of
--- what it maps
---@type string?
local sourcing_ft

-- Mappings this tree makes outside of any `keys`
local set = vim.keymap.set
---@diagnostic disable-next-line: duplicate-set-field
vim.keymap.set = function(mode, lhs, rhs, opts)
  opts = opts or {}
  for level = 2, 12 do
    local info = debug.getinfo(level, 'S')
    if not info then break end
    local file = relative((info.source:gsub('^@', '')))
    -- lazy.nvim's own `keys` stubs come through `config.lazy`, and the
    -- wrappers of `util.plugin` pass on what they were given
    if
      file
      and file ~= 'lua/config/lazy.lua'
      and file ~= 'lua/util/plugin.lua'
    then
      if opts.desc and opts.desc ~= '' then
        table.insert(maps, {
          lhs = normalize(lhs),
          modes = mode_list(mode),
          desc = opts.desc,
          scope = sourcing_ft and 'ft: ' .. sourcing_ft
            or opts.buffer and 'buffer'
            or '',
          from = file,
        })
      end
      break
    end
  end
  return set(mode, lhs, rhs, opts)
end

--- Keys of a lazy.nvim style list
---@param keys table[]
---@param scope fun(key: table): string
---@param from string
local function add_keys(keys, scope, from)
  local Keys = require('lazy.core.handler.keys')
  for _, key in pairs(Keys.resolve(keys)) do
    if key.rhs == '' and key.desc and vim.startswith(key.desc, '+') then
      -- One prefix may be a group of several plugins, each in its own
      -- filetypes: Laravel's `<localleader>l` and Octo's
      local lhs, name = normalize(key.lhs), key.desc:sub(2)
      local names = key_groups[lhs] and vim.split(key_groups[lhs], ' / ') or {}
      if not vim.list_contains(names, name) then table.insert(names, name) end
      key_groups[lhs] = table.concat(names, ' / ')
    elseif key.desc and key.desc ~= '' then
      table.insert(maps, {
        lhs = normalize(key.lhs),
        modes = mode_list(key.mode),
        desc = key.desc,
        scope = scope(key),
        from = from,
      })
    end
  end
end

--- Group names by prefix, from which-key's `spec`
---@return table<string, string>
local function groups()
  local ret = {}
  local function walk(spec)
    if type(spec) ~= 'table' then return end
    if type(spec[1]) == 'string' and spec.group then
      local name = type(spec.group) == 'function' and spec.group() or spec.group
      ret[normalize(spec[1])] = name
    end
    for _, child in ipairs(spec) do
      walk(child)
    end
  end
  walk(require('util.plugin').opts('which-key.nvim').spec)
  return ret
end

--- Call the `on_attach` of every loaded plugin on `bufnr`, for the keys it
--- maps in the buffers it attaches to, such as gitsigns' hunk keys
---@param bufnr integer
local function attach(bufnr)
  local Config = require('lazy.core.config')
  local names = vim.tbl_keys(Config.plugins)
  table.sort(names)
  for _, name in ipairs(names) do
    if Config.plugins[name]._.loaded then
      local ok, opts = pcall(require('util.plugin').opts, name)
      if
        ok
        and type(opts) == 'table'
        and type(opts.on_attach) == 'function'
      then
        pcall(opts.on_attach, bufnr)
      end
    end
  end
end

--- Source every `ftplugin/<ft>.lua` of this tree in a buffer of its own, for
--- the `<localleader>` keys they map: sourced rather than set as the
--- filetype, which would start that filetype's servers and plugins too
local function source_ftplugins()
  local files =
    vim.fn.glob(vim.fs.joinpath(root, 'ftplugin', '*.lua'), true, true)
  table.sort(files)
  for _, file in ipairs(files) do
    local bufnr = vim.api.nvim_create_buf(true, false)
    sourcing_ft = vim.fn.fnamemodify(file, ':t:r')
    vim.api.nvim_buf_call(bufnr, function() pcall(vim.cmd.source, file) end)
    sourcing_ft = nil
  end
end

--- Fire the `FileType` autocmds of this tree's tools (the `dy_*` groups the
--- `plugin/` shims make) in a buffer of each filetype they name, for the
--- `<localleader>` keys their `attach` maps. Only those groups run, and the
--- filetype is set without events, so no server or parser starts.
---
--- Several tools map only in a buffer that looks like theirs: a manifest, a
--- file of a Helm chart, a schedule, an AsyncAPI document. Every buffer is
--- one of all of these at once, so each of them maps what it would.
local function attach_tools()
  local chart = vim.fn.tempname()
  vim.fn.mkdir(vim.fs.joinpath(chart, 'templates'), 'p')
  vim.fn.writefile(
    { 'name: keymaps-doc' },
    vim.fs.joinpath(chart, 'Chart.yaml')
  )
  local lines = {
    'asyncapi: 3.0.0',
    '"asyncapi": "3.0.0",',
    'apiVersion: batch/v1',
    'kind: CronJob',
    'schedule: "0 * * * *"',
  }

  -- One entry per group, holding every filetype it names
  local by_group = {} ---@type table<string, { id: integer, fts: string[] }>
  for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ event = 'FileType' })) do
    local name = autocmd.group_name
    if name and name:match('^dy_') then
      by_group[name] = by_group[name] or { id = autocmd.group, fts = {} }
      if not vim.list_contains(by_group[name].fts, autocmd.pattern) then
        table.insert(by_group[name].fts, autocmd.pattern)
      end
    end
  end
  local names = vim.tbl_keys(by_group)
  table.sort(names)

  for _, name in ipairs(names) do
    local group = by_group[name]
    sourcing_ft = table.concat(group.fts, ', ')
    for _, ft in ipairs(group.fts) do
      -- A pattern such as `yaml.*` is not a filetype a buffer can have
      if not ft:find('[*?[]') then
        local bufnr = vim.api.nvim_create_buf(true, false)
        vim.api.nvim_buf_set_name(
          bufnr,
          vim.fs.joinpath(chart, 'templates', ('%s-%s.yaml'):format(name, ft))
        )
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd('noautocmd setlocal filetype=' .. ft)
          local ok, err = pcall(
            vim.api.nvim_exec_autocmds,
            'FileType',
            { group = group.id, pattern = ft, modeline = false }
          )
          if not ok then
            io.stderr:write(
              ('keymaps-doc: %s on %s: %s\n'):format(name, ft, err)
            )
          end
        end)
      end
    end
    sourcing_ft = nil
  end
end

local function collect()
  local Config = require('lazy.core.config')
  local Plugin = require('lazy.core.plugin')
  local names = vim.tbl_keys(Config.spec.plugins)
  table.sort(names)
  for _, name in ipairs(names) do
    local ok, keys =
      pcall(Plugin.values, Config.spec.plugins[name], 'keys', true)
    if ok and keys then
      add_keys(keys, function(key)
        local ft = key.ft
        if not ft then return '' end
        return 'ft: ' .. (type(ft) == 'table' and table.concat(ft, ', ') or ft)
      end, name)
    end
  end
  local servers = require('util.plugin').opts('nvim-lspconfig').servers or {}
  local server_names = vim.tbl_keys(servers)
  table.sort(server_names)
  for _, server in ipairs(server_names) do
    local opts = servers[server]
    if type(opts) == 'table' and opts.keys and opts.enabled ~= false then
      add_keys(
        opts.keys,
        function() return server == '*' and 'LSP' or 'LSP: ' .. server end,
        'nvim-lspconfig'
      )
    end
  end
end

--- Keys set everywhere, in one mode, with two meanings from two places
---@return string[]
local function conflicts()
  local by_key = {} ---@type table<string, DyKeymap[]>
  for _, map in ipairs(maps) do
    if map.scope == '' then
      for _, mode in ipairs(map.modes) do
        local id = mode .. ' ' .. map.lhs
        by_key[id] = by_key[id] or {}
        table.insert(by_key[id], map)
      end
    end
  end
  local found = {}
  for id, list in pairs(by_key) do
    local first = list[1]
    for _, other in ipairs(list) do
      if other.desc ~= first.desc and other.from ~= first.from then
        table.insert(
          found,
          ('%s: "%s" (%s) and "%s" (%s)'):format(
            id,
            first.desc,
            first.from,
            other.desc,
            other.from
          )
        )
        break
      end
    end
  end
  table.sort(found)
  return found
end

--- One line per key and scope, its modes merged
---@return DyKeymap[]
local function merged()
  local by_key, order = {}, {}
  for _, map in ipairs(maps) do
    local id = map.lhs .. '\0' .. map.scope .. '\0' .. map.desc
    if by_key[id] then
      for _, mode in ipairs(map.modes) do
        if not vim.list_contains(by_key[id].modes, mode) then
          table.insert(by_key[id].modes, mode)
        end
      end
      table.sort(by_key[id].modes)
    else
      by_key[id] = vim.deepcopy(map)
      table.insert(order, id)
    end
  end
  return vim.tbl_map(function(id) return by_key[id] end, order)
end

--- The longest group prefix of `lhs`, other than `lhs` itself
---@param lhs string
---@param names table<string, string>
---@return string
local function section(lhs, names)
  local best = ''
  for prefix in pairs(names) do
    if
      #prefix > #best
      and #prefix < #lhs
      and lhs:sub(1, #prefix) == prefix
      and prefix ~= '<leader>'
    then
      best = prefix
    end
  end
  if best == '' and vim.startswith(lhs, '<leader>') then
    -- A `<leader>` key outside every group: one key on its own goes with the
    -- other single keys, a longer one under its first key
    local rest = lhs:sub(#'<leader>' + 1)
    local key = rest:match('^<[^>]+>') or rest:sub(1, 1)
    best = key == rest and '<leader>' or '<leader>' .. key
  end
  return best
end

---@param names table<string, string>
local function render(names)
  names = vim.tbl_extend('keep', names, key_groups)
  local sections = {} ---@type table<string, DyKeymap[]>
  for _, map in ipairs(merged()) do
    local prefix = section(map.lhs, names)
    sections[prefix] = sections[prefix] or {}
    table.insert(sections[prefix], map)
  end
  local prefixes = vim.tbl_keys(sections)
  table.sort(prefixes, function(a, b)
    if (a == '') ~= (b == '') then return b == '' end
    return a:lower() < b:lower() or (a:lower() == b:lower() and a < b)
  end)

  local lines = {
    '*dyneo-keymaps.txt*   Every mapping of DyNeo',
    '',
    ('%78s'):format('*dyneo-keymaps*'),
    '',
    'Generated by `scripts/keymaps-doc.sh` from the configuration as it loads,',
    'with every plugin and language turned on; run it again after changing a',
    'mapping.  See |dyneo-mappings| for the ones worth knowing first.',
    '',
    'Modes are those of |map-modes|.  The last column says where a mapping',
    'applies when it is not everywhere: `ft:` for the filetypes listed, `LSP`',
    'for buffers whose language server supports it, `buffer` for buffers a',
    'plugin sets it up in.  A filetype or server mapping takes over a global',
    'one of the same keys in those buffers.',
    '',
  }
  for _, prefix in ipairs(prefixes) do
    local title = prefix == '' and 'Other keys'
      or prefix == '<leader>' and '<leader>  single keys'
      or ('%s  %s'):format(prefix, names[prefix] or '')
    vim.list_extend(lines, { ('='):rep(78), vim.trim(title), '' })
    local entries = sections[prefix]
    table.sort(entries, function(a, b)
      if a.lhs ~= b.lhs then return a.lhs < b.lhs end
      if a.scope ~= b.scope then return a.scope < b.scope end
      local am, bm = table.concat(a.modes), table.concat(b.modes)
      if am ~= bm then return am < bm end
      return a.desc < b.desc
    end)
    for _, map in ipairs(entries) do
      local line = ('%-22s %-6s %s'):format(
        '`' .. map.lhs .. '`',
        table.concat(map.modes, ''),
        map.desc
      )
      if map.scope ~= '' then line = ('%s  (%s)'):format(line, map.scope) end
      table.insert(lines, line)
    end
    table.insert(lines, '')
  end
  table.insert(lines, 'vim:tw=78:ts=8:noet:ft=help:norl:')
  vim.fn.writefile(lines, output)
  io.stdout:write(
    ('keymaps-doc: %d mappings written to %s\n'):format(#merged(), output)
  )
end

vim.api.nvim_create_autocmd('VimEnter', {
  once = true,
  -- For the file opened below to fire the events that load plugins
  nested = true,
  callback = function()
    -- Only `keymaps-doc.lua` quits Neovim: an error here must quit too, not
    -- leave it waiting until the shell script's timeout kills it
    local names
    local ok, err = pcall(function()
      -- which-key takes its `spec` apart as it sets up, so the groups are
      -- read before `VeryLazy` loads it
      names = groups()
      -- Headless there is no UI to enter, so `VeryLazy` is fired by hand: it
      -- is what loads `config.keymaps`
      vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
      -- The plugins behind `LazyFile` map their toggles as they set up, so a
      -- file is opened for them. It has no filetype, which keeps language
      -- servers and parsers out of it.
      pcall(vim.cmd.edit, vim.fn.fnameescape(vim.fn.tempname()))
      attach(vim.api.nvim_get_current_buf())
      source_ftplugins()
      attach_tools()
    end)
    if not ok then
      io.stderr:write('keymaps-doc: ' .. tostring(err) .. '\n')
      return vim.cmd('cquit')
    end
    vim.defer_fn(function()
      local problems = {}
      local ok, err = pcall(function()
        collect()
        render(names)
        for _, line in ipairs(dead) do
          table.insert(problems, 'dead mapping: ' .. line)
        end
        for _, line in ipairs(conflicts()) do
          table.insert(problems, 'conflicting mapping: ' .. line)
        end
      end)
      if not ok then table.insert(problems, tostring(err)) end
      for _, line in ipairs(problems) do
        io.stderr:write('keymaps-doc: ' .. line .. '\n')
      end
      vim.cmd(#problems > 0 and 'cquit' or 'qall!')
    end, 1000)
  end,
})
