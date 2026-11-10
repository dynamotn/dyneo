--- i18n keys in the code, the way i18n-ally shows them: the translation of a
--- key beside it, a jump to its entry, and a report of the keys missing in a
--- locale or never used
---
--- The locale files of a project are found by the common layouts in
--- `M.LAYOUTS`, or by the `paths` of a `.nvim/i18n.json` at its root. They are
--- read once per project and kept until one of them is written: JSON with
--- `vim.json`, YAML through `yq` when it is installed (there is no YAML decoder
--- in Neovim). Nested keys are flattened with `.`.
---
--- Keys are found in the code by the calls in `M.CALLS`, on one line each. A
--- key that is not a plain string (a template, a concatenation, a variable,
--- a Rails lazy lookup `t('.key')`) is dynamic: it makes the keys it could
--- name "maybe unused" instead of unused.
local M = {}

local notify = require('util.notify').titled('I18n')

--- Characters of a translation shown beside its key
M.MAX_HINT = 40

--- Bytes of one locale file read; a bigger one is skipped and said so
M.MAX_FILE_BYTES = 2 * 1024 * 1024

--- Locale files read in one project
M.MAX_FILES = 300

--- Milliseconds `git grep` and `yq` may take
M.TIMEOUT = 30 * 1000

--- Output of `git grep` kept
M.MAX_BYTES = 8 * 1024 * 1024

--- Milliseconds of quiet before the hints of a buffer are placed again
M.DEBOUNCE = 250

--- Lines longer than this (minified code) are not searched for keys
M.MAX_LINE = 2000

--- Filetypes whose buffers get the jump key, and the hints when on
M.FILETYPES = {
  'javascript',
  'javascriptreact',
  'typescript',
  'typescriptreact',
  'vue',
  'svelte',
  'ruby',
  'eruby',
  'php',
}

--- Files the report searches for keys, as git pathspecs
M.SOURCES = {
  '*.js',
  '*.jsx',
  '*.mjs',
  '*.cjs',
  '*.ts',
  '*.tsx',
  '*.mts',
  '*.cts',
  '*.vue',
  '*.svelte',
  '*.rb',
  '*.erb',
  '*.php',
}

--- Where locale files live, relative to the project root: `*` and `**` as
--- in a glob, `{lang}` the part naming the locale. A path without `{lang}`
--- holds the locales as its top-level keys, as Rails does. Laravel's
--- `lang/<lang>/*.php` is PHP code, not data, and is not read.
M.LAYOUTS = {
  'locales/{lang}/*.json',
  'locales/{lang}.json',
  'public/locales/{lang}/*.json',
  'src/i18n/{lang}.json',
  'messages/{lang}.json',
  'config/locales/**/*.yml',
  'translations/*.{lang}.yaml',
  'translations/*.{lang}.yml',
}

---@class DyI18nCall
---@field name string
---@field pattern string Lua pattern up to the first argument
---@field grep string Extended regex of the name, for `git grep`

--- The calls taking a key as their first argument. `t` covers `t()`,
--- `i18n.t()`, `I18n.t()`, `$t()` and the `t` of `useTranslations`.
---@type DyI18nCall[]
M.CALLS = {
  { name = 't', pattern = '%f[%w_$]%$?t%s*%(%s*', grep = 't' },
  { name = 'trans', pattern = '%f[%w_$]trans%s*%(%s*', grep = 'trans' },
  { name = '__', pattern = '%f[%w_$]__%s*%(%s*', grep = '__' },
  { name = '$_', pattern = '%f[%w_$]%$_%s*%(%s*', grep = '\\$_' },
}

---@class DyI18nUsage
---@field key? string The key, when it is a plain string
---@field prefix? string Of a dynamic key: what it starts with
---@field suffix? string Of a dynamic key: what it ends with
---@field s integer Byte where the argument starts, 1-based
---@field e integer Byte where it ends: the closing quote of a string

---@class DyI18nEntry
---@field value string
---@field file string Absolute path
---@field path string[] The keys leading to it in the file

---@class DyI18nIndex
---@field root string
---@field default? string The locale shown in hints and jumped to
---@field langs string[]
---@field values table<string, table<string, DyI18nEntry>> By locale, then key
---@field files table<string, boolean> The locale files read
---@field patterns string[] Lua patterns of locale paths relative to the root
---@field problems string[] Files skipped, and why
---@field error? string The override file is malformed
---@field told? boolean Its problems were said

--- Index or pending fill of each project root
---@type table<string, { index?: DyI18nIndex, waiting: fun(index: DyI18nIndex)[] }>
M.cache = {}

--- The project root of each directory, `false` for none
---@type table<string, string|false>
M.roots = {}

--- Hints are off until `:DyI18n hints`, to stay quiet
M.hints = false

local ns = vim.api.nvim_create_namespace('dy_i18n')

--- Whether `name` looks like a locale: `en`, `pt-BR`, `zh_Hans`
---@param name string
---@return boolean
function M.is_lang(name)
  return name:match('^%a%a%a?$') ~= nil
    or name:match('^%a%a%a?[-_]%w%w+$') ~= nil
end

--- The Lua pattern matching the paths of `layout`, `{lang}` captured
---@param layout string
---@return string
function M.glob_pattern(layout)
  local out = layout
    :gsub('[%^%$%(%)%%%.%[%]%+%-%?]', '%%%0')
    :gsub('{lang}', '\1')
    :gsub('%*%*/', '\2')
    :gsub('%*', '[^/]*')
    :gsub('\2', '.-')
    :gsub('\1', '([^/]+)')
  return '^' .. out .. '$'
end

--- The text of `file`, or why it was not read
---@param file string
---@return string? text
---@return string? why
local function read(file)
  local stat = vim.uv.fs_stat(file)
  if not stat then return nil, 'cannot be read' end
  if stat.size > M.MAX_FILE_BYTES then
    return nil, ('is bigger than %d bytes'):format(M.MAX_FILE_BYTES)
  end
  local ok, lines = pcall(vim.fn.readfile, file, 'b')
  if not ok then return nil, 'cannot be read' end
  return table.concat(lines, '\n')
end

---@class DyI18nConfig
---@field paths string[]
---@field default? string
---@field error? string

--- The layouts of `root`: those of its `.nvim/i18n.json`, or `M.LAYOUTS`
---@param root string
---@return DyI18nConfig
function M.config(root)
  local file = vim.fs.joinpath(root, '.nvim', 'i18n.json')
  if not vim.uv.fs_stat(file) then return { paths = M.LAYOUTS } end
  local function bad(why) return { paths = {}, error = file .. ': ' .. why } end
  local text, why = read(file)
  if not text then return bad(why) end
  local ok, data = pcall(vim.json.decode, text)
  if not ok or type(data) ~= 'table' then return bad('not a JSON object') end
  if type(data.paths) ~= 'table' or #data.paths == 0 then
    return bad('`paths` must be a list of paths relative to the project')
  end
  for _, path in ipairs(data.paths) do
    -- The override comes with the project: it names files of the project only
    if
      type(path) ~= 'string'
      or path:sub(1, 1) == '/'
      or path:find('..', 1, true)
    then
      return bad(('`%s` is not a path inside the project'):format(path))
    end
  end
  if data.default ~= nil and type(data.default) ~= 'string' then
    return bad('`default` must be a locale name')
  end
  return { paths = data.paths, default = data.default }
end

--- Add the leaves of `tree` to `values`, keyed by their path joined with `.`
---@param tree table
---@param path string[]
---@param skip integer Leading keys of `path` left out of the key
---@param file string
---@param values table<string, DyI18nEntry>
local function flatten(tree, path, skip, file, values)
  for name, value in pairs(tree) do
    local here = vim.list_extend(vim.list_slice(path), { tostring(name) })
    if type(value) == 'table' and type(next(value)) == 'string' then
      flatten(value, here, skip, file, values)
    elseif value ~= vim.NIL and type(value) ~= 'table' then
      local key = table.concat(here, '.', skip + 1)
      -- Two files of one locale defining a key: the first, in path order
      if not values[key] then
        values[key] = { value = tostring(value), file = file, path = here }
      end
    end
  end
end

--- The leaves of `data` as keys, under `lang` or its top-level locales
---@param index DyI18nIndex
---@param data any
---@param file string
---@param lang? string
local function add(index, data, file, lang)
  if type(data) ~= 'table' then
    table.insert(index.problems, file .. ' holds no keys')
    return
  end
  local function values(name)
    if not index.values[name] then
      index.values[name] = {}
      table.insert(index.langs, name)
    end
    return index.values[name]
  end
  if lang then return flatten(data, {}, 0, file, values(lang)) end
  for name, tree in pairs(data) do
    if type(name) == 'string' and M.is_lang(name) and type(tree) == 'table' then
      flatten(tree, { name }, 1, file, values(name))
    end
  end
end

--- Read the locale files of `root` into an index for `done`
---@param root string
---@param done fun(index: DyI18nIndex)
local function build(root, done)
  local config = M.config(root)
  ---@type DyI18nIndex
  local index = {
    root = root,
    langs = {},
    values = {},
    files = {},
    patterns = {},
    problems = {},
    error = config.error,
  }
  local found = {} ---@type { file: string, lang?: string }[]
  for _, layout in ipairs(config.paths) do
    local pattern = M.glob_pattern(layout)
    table.insert(index.patterns, pattern)
    local glob = vim.fs.joinpath(root, (layout:gsub('{lang}', '*')))
    for _, file in ipairs(vim.fn.glob(glob, false, true)) do
      local rel = file:sub(#root + 2)
      local lang = rel:match(pattern)
      local named = layout:find('{lang}', 1, true)
      if
        not index.files[file] and (not named or (lang and M.is_lang(lang)))
      then
        index.files[file] = true
        table.insert(found, { file = file, lang = named and lang or nil })
      end
    end
  end
  table.sort(found, function(a, b) return a.file < b.file end)
  if #found > M.MAX_FILES then
    table.insert(
      index.problems,
      ('%d locale files: only the first %d are read'):format(
        #found,
        M.MAX_FILES
      )
    )
    found = vim.list_slice(found, 1, M.MAX_FILES)
  end

  local yaml = {}
  for _, item in ipairs(found) do
    if item.file:match('%.ya?ml$') then
      table.insert(yaml, item)
    else
      local text, why = read(item.file)
      local ok, data = pcall(vim.json.decode, text or '')
      if not text then
        table.insert(index.problems, ('%s %s'):format(item.file, why))
      elseif not ok then
        table.insert(index.problems, item.file .. ' is not valid JSON')
      else
        add(index, data, item.file, item.lang)
      end
    end
  end

  local function finish()
    table.sort(index.langs)
    if config.default and not index.values[config.default] then
      table.insert(
        index.problems,
        ('the default locale `%s` has no file'):format(config.default)
      )
    end
    index.default = index.values[config.default or ''] and config.default
      or index.values.en and 'en'
      or index.langs[1]
    done(index)
  end

  if #yaml == 0 then return finish() end
  if vim.fn.executable('yq') ~= 1 then
    table.insert(
      index.problems,
      ('%d YAML locale files skipped: yq is not installed'):format(#yaml)
    )
    return finish()
  end
  local system = require('util.system')
  system.each(yaml, 4, function(item, next)
    local stat = vim.uv.fs_stat(item.file)
    if not stat or stat.size > M.MAX_FILE_BYTES then
      table.insert(index.problems, item.file .. ' is too big or unreadable')
      return next()
    end
    system.run(
      { 'yq', '-o=json', '-I=0', '.', item.file },
      { timeout = M.TIMEOUT, max_bytes = 4 * M.MAX_FILE_BYTES },
      function(result)
        local ok, data = pcall(vim.json.decode, result.stdout or '')
        if result.code ~= 0 or result.cut or not ok then
          table.insert(
            index.problems,
            ('%s: %s'):format(
              item.file,
              result.code ~= 0 and system.failure(result, 'yq')
                or 'yq gave no JSON'
            )
          )
        else
          add(index, data, item.file, item.lang)
        end
        next()
      end
    )
  end, finish)
end

--- Hand `done` the index of `root`, read once until a locale file is written
---@param root string
---@param done fun(index: DyI18nIndex)
function M.index(root, done)
  local state = M.cache[root]
  if state and state.index then return done(state.index) end
  if state then return table.insert(state.waiting, done) end
  state = { waiting = { done } }
  M.cache[root] = state
  build(root, function(index)
    if M.cache[root] == state then state.index = index end
    local waiting = state.waiting
    state.waiting = {}
    for _, callback in ipairs(waiting) do
      callback(index)
    end
  end)
end

--- Whether `dir` has locale files, or an override
---@param dir string
---@return boolean
local function has_locales(dir)
  if vim.uv.fs_stat(vim.fs.joinpath(dir, '.nvim', 'i18n.json')) then
    return true
  end
  for _, layout in ipairs(M.LAYOUTS) do
    local glob = vim.fs.joinpath(dir, (layout:gsub('{lang}', '*')))
    if vim.fn.glob(glob, false, true)[1] then return true end
  end
  return false
end

--- The nearest directory of `bufnr`'s file with locale files, up to the
--- repository root or `$HOME`; nil when there is none
---@param bufnr integer
---@return string?
function M.root(bufnr)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' or vim.bo[bufnr].buftype ~= '' then return nil end
  local start = vim.fs.dirname(vim.fs.normalize(name))
  start = vim.uv.fs_realpath(start) or start
  if M.roots[start] ~= nil then return M.roots[start] or nil end
  local home = vim.uv.os_homedir()
  local dir, found = start, false
  while dir do
    if has_locales(dir) then
      found = dir
      break
    end
    local up = vim.fs.dirname(dir)
    if up == dir or dir == home or vim.uv.fs_stat(dir .. '/.git') then break end
    dir = up
  end
  M.roots[start] = found
  return found or nil
end

--- The first argument of a call starting at byte `at` of `line`
---@param line string
---@param at integer
---@return DyI18nUsage?
local function argument(line, at)
  local quote = line:sub(at, at)
  if quote == "'" or quote == '"' or quote == '`' then
    -- shortcut: an escaped quote ends the key early; keys rarely hold quotes
    local close = line:find(quote, at + 1, true)
    if not close then return nil end
    local text = line:sub(at + 1, close - 1)
    if quote == '`' and text:find('${', 1, true) then
      return {
        prefix = text:match('^(.-)%${'),
        suffix = text:match('.*}(.*)$'),
        s = at,
        e = close,
      }
    end
    local after = line:sub(close + 1):match('^%s*(%S)')
    -- Concatenated: `'a.' + x` in JavaScript, `'a.' . $x` in PHP
    if after == '+' or after == '.' then
      return { prefix = text, suffix = '', s = at, e = close }
    end
    -- A Rails lazy lookup, relative to the view
    if text:sub(1, 1) == '.' then
      return { prefix = '', suffix = text, s = at, e = close }
    end
    if text == '' then return nil end
    return { key = text, s = at, e = close }
  end
  local symbol = line:match('^:([%a_][%w_]*)', at)
  if symbol then return { key = symbol, s = at, e = at + #symbol } end
  local rest = line:sub(at)
  -- No argument, or one on the next line: nothing to tell
  if rest == '' or rest:match('^%)') then return nil end
  return { prefix = '', suffix = '', s = at, e = at }
end

--- The keys passed to the calls of `M.CALLS` on `line`, in order
---@param line string
---@return DyI18nUsage[]
function M.extract(line)
  local found, seen = {}, {}
  if #line > M.MAX_LINE then return found end
  for _, call in ipairs(M.CALLS) do
    local init = 1
    while true do
      local _, e = line:find(call.pattern, init)
      if not e then break end
      init = e + 1
      if not seen[e] then
        seen[e] = true
        local usage = argument(line, e + 1)
        if usage then table.insert(found, usage) end
      end
    end
  end
  table.sort(found, function(a, b) return a.s < b.s end)
  return found
end

local PLURALS = { 'zero', 'one', 'two', 'few', 'many', 'other' }

--- `key` without an i18next plural suffix (`_one`, `_other`, ...)
---@param key string
---@return string
function M.canonical(key)
  local base, form = key:match('^(.+)_(%l+)$')
  if base and vim.list_contains(PLURALS, form) then return base end
  return key
end

--- The entry of `key` in `lang`: as written, as an i18next plural, or
--- without its `ns:` namespace
---@param index DyI18nIndex
---@param lang string
---@param key string
---@return DyI18nEntry?
function M.lookup(index, lang, key)
  local values = index.values[lang]
  if not values then return nil end
  -- shortcut: a namespaced key is looked up in every namespace of the locale
  local bare = key:match('^[%w_-]+:(.+)$')
  return values[key]
    or values[key .. '_other']
    or bare and (values[bare] or values[bare .. '_other'])
    or nil
end

--- The line of the entry at `path` in the lines of its file: each key looked
--- for below the one before it
---@param lines string[]
---@param path string[]
---@return integer
function M.locate(lines, path)
  local lnum = 1
  for _, name in ipairs(path) do
    local key = vim.pesc(name)
    local patterns = {
      '"' .. key .. '"%s*:',
      "'" .. key .. "'%s*:",
      '^%s*' .. key .. '%s*:',
    }
    for i = lnum, #lines do
      local hit = false
      for _, pattern in ipairs(patterns) do
        if lines[i]:find(pattern) then hit = true end
      end
      if hit then
        lnum = i
        break
      end
    end
  end
  return lnum
end

--- `value` on one line, cut to `M.MAX_HINT` characters
---@param value string
---@return string
function M.truncate(value)
  value = vim.trim(value:gsub('%s+', ' '))
  if vim.fn.strchars(value) <= M.MAX_HINT then return value end
  return vim.fn.strcharpart(value, 0, M.MAX_HINT - 1) .. '…'
end

--- Lines shown of `bufnr` in the windows of the current tab, 1-based ranges
---@param bufnr integer
---@return integer[][]
function M.visible(bufnr)
  local ranges = {}
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    table.insert(ranges, { vim.fn.line('w0', win), vim.fn.line('w$', win) })
  end
  return ranges
end

--- Show the default-locale value after each key on the lines of `ranges`
---@param bufnr integer
---@param index DyI18nIndex
---@param ranges integer[][]
function M.place(bufnr, index, ranges)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local lang = index.default
  if not lang then return end
  local done = {}
  for _, range in ipairs(ranges) do
    local lines =
      vim.api.nvim_buf_get_lines(bufnr, range[1] - 1, range[2], false)
    for i, line in ipairs(lines) do
      local row = range[1] + i - 2
      if not done[row] then
        done[row] = true
        for _, usage in ipairs(M.extract(line)) do
          if usage.key then
            local entry = M.lookup(index, lang, usage.key)
            vim.api.nvim_buf_set_extmark(bufnr, ns, row, usage.e, {
              virt_text = {
                entry and { ' ' .. M.truncate(entry.value), 'Comment' }
                  or { (' missing in %s'):format(lang), 'DiagnosticWarn' },
              },
              virt_text_pos = 'inline',
            })
          end
        end
      end
    end
  end
end

--- Say once per index what keeps it from being complete
---@param index DyI18nIndex
local function tell(index)
  if index.told then return end
  index.told = true
  if index.error then return notify(index.error, vim.log.levels.ERROR) end
  if #index.problems > 0 then
    notify(table.concat(index.problems, '\n'), vim.log.levels.WARN)
  end
end

--- Place the hints of `bufnr` again, or clear them outside a project with
--- locales
---@param bufnr integer
function M.refresh(bufnr)
  if not vim.api.nvim_buf_is_loaded(bufnr) then return end
  local root = M.root(bufnr)
  if not root then return vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1) end
  M.index(root, function(index)
    if not M.hints or not vim.api.nvim_buf_is_loaded(bufnr) then return end
    tell(index)
    M.place(bufnr, index, M.visible(bufnr))
  end)
end

local pending = {} ---@type table<integer, boolean>
local timer ---@type uv.uv_timer_t?

--- Refresh the hints of `bufnr` once things are quiet for `M.DEBOUNCE`
---@param bufnr integer
function M.schedule(bufnr)
  if not M.hints or not vim.b[bufnr].dy_i18n then return end
  pending[bufnr] = true
  timer = timer or assert(vim.uv.new_timer())
  timer:stop()
  timer:start(
    M.DEBOUNCE,
    0,
    vim.schedule_wrap(function()
      local bufs = vim.tbl_keys(pending)
      pending = {}
      for _, buf in ipairs(bufs) do
        if vim.api.nvim_buf_is_valid(buf) then M.refresh(buf) end
      end
    end)
  )
end

--- Schedule every buffer shown in the current tab
local function schedule_shown()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    M.schedule(vim.api.nvim_win_get_buf(win))
  end
end

--- Turn the hints on or off
---@param on? boolean Toggle when nil
function M.toggle(on)
  if on == nil then on = not M.hints end
  M.hints = on
  if on then
    local group = vim.api.nvim_create_augroup('dy_i18n_hints', { clear = true })
    vim.api.nvim_create_autocmd({ 'BufEnter', 'TextChanged', 'WinScrolled' }, {
      group = group,
      callback = function(args)
        local bufnr = args.buf
        if args.event == 'WinScrolled' then
          local win = tonumber(args.match)
          if win and vim.api.nvim_win_is_valid(win) then
            bufnr = vim.api.nvim_win_get_buf(win)
          end
        end
        M.schedule(bufnr)
      end,
    })
    schedule_shown()
  else
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_i18n_hints')
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
      if vim.api.nvim_buf_is_loaded(bufnr) then
        vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
      end
    end
  end
  notify(on and 'Translation hints on' or 'Translation hints off')
end

--- Forget the index a written file belongs to: a locale file, a new one of
--- a known layout, or the override
---@param file string
function M.written(file)
  file = vim.uv.fs_realpath(file) or file
  M.roots = {}
  local contains = require('util.root').contains
  local changed = false
  for root, state in pairs(M.cache) do
    if contains(root, file) then
      local rel = file:sub(#root + 2)
      local stale = not state.index
        or state.index.files[file]
        or rel == '.nvim/i18n.json'
      for _, pattern in ipairs(state.index and state.index.patterns or {}) do
        stale = stale or rel:match(pattern) ~= nil
      end
      if stale then
        M.cache[root] = nil
        changed = true
      end
    end
  end
  if changed then schedule_shown() end
end

--- The key under the cursor, or the first on the line
---@return DyI18nUsage?
local function key_at_cursor()
  local col = vim.api.nvim_win_get_cursor(0)[2] + 1
  local usages = vim.tbl_filter(
    function(usage) return usage.key ~= nil end,
    M.extract(vim.api.nvim_get_current_line())
  )
  for _, usage in ipairs(usages) do
    if col >= usage.s and col <= usage.e then return usage end
  end
  return usages[1]
end

--- Go to the entry of the key under the cursor in the default locale
function M.jump()
  local usage = key_at_cursor()
  if not usage then return notify('No i18n key under the cursor') end
  local root = M.root(0)
  if not root then
    return notify('No locale files around this file', vim.log.levels.WARN)
  end
  local key = assert(usage.key)
  M.index(root, function(index)
    tell(index)
    if not index.default then
      return notify('No locale was read', vim.log.levels.WARN)
    end
    local entry = M.lookup(index, index.default, key)
    if not entry then
      return notify(
        ('`%s` is not in the default locale (%s)'):format(key, index.default),
        vim.log.levels.WARN
      )
    end
    vim.cmd.edit(vim.fn.fnameescape(entry.file))
    local lnum =
      M.locate(vim.api.nvim_buf_get_lines(0, 0, -1, false), entry.path)
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  end)
end

--- The usages in the output of `git grep -n -z`: `path\0lnum\0line` per hit
---@param text string
---@param root string
---@return (DyI18nUsage|{ file: string, lnum: integer })[]
function M.parse_grep(text, root)
  local usages = {}
  for record in vim.gsplit(text, '\n', { trimempty = true }) do
    local file, lnum, line = record:match('^([^%z]+)%z(%d+)%z(.*)$')
    if file then
      for _, usage in ipairs(M.extract(line)) do
        usage.file = vim.fs.joinpath(root, file)
        usage.lnum = tonumber(lnum)
        table.insert(usages, usage)
      end
    end
  end
  return usages
end

--- Find the keys used in the code below `root`
---@param root string
---@param done fun(usages?: table[], failure?: string, cut?: boolean)
function M.scan(root, done)
  local system = require('util.system')
  local names = vim.tbl_map(function(call) return call.grep end, M.CALLS)
  local regex = ('(^|[^[:alnum:]_$])(%s)[[:space:]]*\\('):format(
    table.concat(names, '|')
  )
  -- `--no-index` searches untracked files too, `--exclude-standard` still
  -- leaves out what git ignores, such as node_modules
  local cmd = {
    'git',
    'grep',
    '--no-index',
    '--exclude-standard',
    '-n',
    '-z',
    '-I',
    '-E',
    regex,
    '--',
  }
  vim.list_extend(cmd, M.SOURCES)
  system.run(
    cmd,
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      if result.code == 1 and not result.cut then return done({}) end
      if
        result.missing
        or result.timed_out
        or (result.code ~= 0 and not result.cut)
      then
        return done(nil, system.failure(result, 'git grep'))
      end
      local text = result.cut and result.stdout:gsub('[^\n]*$', '')
        or result.stdout
      done(M.parse_grep(text, root), nil, result.cut)
    end
  )
end

---@class DyI18nItem
---@field kind 'missing'|'gap'|'unused'|'maybe'
---@field key string
---@field filename string
---@field lnum integer
---@field text string
---@field type string

--- What is wrong with the keys of `index` against their `usages`: keys used
--- but missing in a locale, keys missing in some locales, keys never used
---@param index DyI18nIndex
---@param usages table[] From `M.scan`
---@param uncertain? boolean Not every usage was read: nothing is surely unused
---@return DyI18nItem[]
function M.compare(index, usages, uncertain)
  local items = {}
  local used, dynamic, told = {}, {}, {}
  for _, usage in ipairs(usages) do
    if usage.key then
      used[usage.key] = true
      used[usage.key:match('^[%w_-]+:(.+)$') or usage.key] = true
      for _, lang in ipairs(index.langs) do
        local id = lang .. '\0' .. usage.key
        if not told[id] and not M.lookup(index, lang, usage.key) then
          told[id] = true
          table.insert(items, {
            kind = 'missing',
            key = usage.key,
            filename = usage.file,
            lnum = usage.lnum,
            text = ('`%s` is used but missing in %s'):format(usage.key, lang),
            type = 'E',
          })
        end
      end
    else
      table.insert(dynamic, usage)
    end
  end

  -- Plural forms differ between languages: a locale has a plural key when
  -- it has any form of it
  local all, plural = {}, {}
  for _, lang in ipairs(index.langs) do
    plural[lang] = {}
    for key in pairs(index.values[lang]) do
      all[key] = true
      plural[lang][M.canonical(key)] = true
    end
  end
  local keys = vim.tbl_keys(all)
  table.sort(keys)
  local lines = {} ---@type table<string, string[]>
  local function at(entry)
    lines[entry.file] = lines[entry.file] or vim.fn.readfile(entry.file)
    return M.locate(lines[entry.file], entry.path)
  end

  local gaps, unused = {}, {}
  for _, key in ipairs(keys) do
    local missing = {}
    local entry = (index.values[index.default or ''] or {})[key]
    local canonical = M.canonical(key)
    for _, lang in ipairs(index.langs) do
      local here = index.values[lang][key]
      entry = entry or here
      if not here and not (canonical ~= key and plural[lang][canonical]) then
        table.insert(missing, lang)
      end
    end
    entry = assert(entry)
    if #missing > 0 then
      table.insert(gaps, {
        kind = 'gap',
        key = key,
        filename = entry.file,
        lnum = at(entry),
        text = ('`%s` is missing in %s'):format(
          key,
          table.concat(missing, ', ')
        ),
        type = 'W',
      })
    end
    if not used[key] and not used[canonical] then
      local reason = uncertain and 'not every file was searched' or nil
      for _, usage in ipairs(dynamic) do
        if
          not reason
          and vim.startswith(key, usage.prefix)
          and vim.endswith(key, usage.suffix)
        then
          reason = ('dynamic key at %s:%d'):format(
            vim.fn.fnamemodify(usage.file, ':.'),
            usage.lnum
          )
        end
      end
      table.insert(unused, {
        kind = reason and 'maybe' or 'unused',
        key = key,
        filename = entry.file,
        lnum = at(entry),
        text = reason and ('`%s` is maybe unused (%s)'):format(key, reason)
          or ('`%s` is never used'):format(key),
        type = reason and 'I' or 'W',
      })
    end
  end
  return vim.list_extend(vim.list_extend(items, gaps), unused)
end

--- Report the keys missing in a locale or never used, in the quickfix list
function M.report()
  local root = M.root(0)
  if not root then
    local cwd = require('util.root')()
    root = has_locales(cwd) and cwd or nil
  end
  if not root then
    return notify(
      'No locale files found (see `:h dyneo-i18n` for the layouts)',
      vim.log.levels.WARN
    )
  end
  M.index(root, function(index)
    tell(index)
    if index.error then return end
    if #index.langs == 0 then
      return notify('No locale was read', vim.log.levels.WARN)
    end
    M.scan(root, function(usages, failure, cut)
      if not usages then return notify(failure, vim.log.levels.ERROR) end
      if cut then
        notify(
          'Too many calls to read: the usages stop at the size cap, so no key is surely unused',
          vim.log.levels.WARN
        )
      end
      local items = M.compare(index, usages, cut)
      local counts = { missing = 0, gap = 0, unused = 0, maybe = 0 }
      for _, item in ipairs(items) do
        counts[item.kind] = counts[item.kind] + 1
      end
      local summary = ('%s: %d used but missing, %d missing in some locale, %d unused, %d maybe unused'):format(
        table.concat(index.langs, ', '),
        counts.missing,
        counts.gap,
        counts.unused,
        counts.maybe
      )
      if #items == 0 then return notify(summary .. ': all keys check out') end
      vim.fn.setqflist({}, ' ', { title = 'I18n', items = items })
      vim.cmd('botright copen')
      notify(summary)
    end)
  end)
end

--- Set up a buffer of `M.FILETYPES`: the jump key, and the hints when on
---@param bufnr integer
function M.attach(bufnr)
  vim.b[bufnr].dy_i18n = true
  vim.keymap.set(
    'n',
    '<localleader>i',
    M.jump,
    { buffer = bufnr, desc = 'Go To Translation (i18n)' }
  )
  M.schedule(bufnr)
end

--- `:DyI18n [report|hints|on|off]`
---@param args string[]
function M.command(args)
  local sub = args[1] or 'report'
  if sub == 'report' then return M.report() end
  if sub == 'hints' then return M.toggle() end
  if sub == 'on' or sub == 'off' then return M.toggle(sub == 'on') end
  notify(
    ('Unknown argument: %s (report, hints, on or off)'):format(sub),
    vim.log.levels.ERROR
  )
end

M.SUBCOMMANDS = { 'report', 'hints', 'on', 'off' }

return M
