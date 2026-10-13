--- Structured logs, read as records rather than as lines of JSON
---
--- A log file, the journal or the logs of a pod open in a buffer of their
--- own, one record per line: time, level, message and request id, whatever
--- the source calls them. JSON lines, logfmt and plain text are told apart
--- line by line. The buffer narrows down to a level and above, to the
--- request under the cursor, or to the records a `jq` expression selects,
--- and is reloaded from its source in place.
---
--- Logs hold tokens and personal data as often as not, so the buffer is
--- kept from every AI integration.
local M = {}

local scratch = require('util.scratch')

local ns = vim.api.nvim_create_namespace('dy_logview')

--- Most lines read from a source
M.MAX_LINES = 20000

--- Lines asked of the journal or of a pod
M.TAIL = 2000

--- Milliseconds a source or `jq` may take
M.TIMEOUT = 60 * 1000

--- Most bytes read from a command; a source followed with `-f` stops here
M.MAX_BYTES = 8 * 1024 * 1024

---@alias DyLogLevel 'trace'|'debug'|'info'|'warn'|'error'

--- The levels, quietest first
M.LEVELS = { 'trace', 'debug', 'info', 'warn', 'error' }

local RANK = { trace = 1, debug = 2, info = 3, warn = 4, error = 5 }

local HIGHLIGHTS = {
  trace = 'Comment',
  debug = 'DiagnosticHint',
  info = 'DiagnosticInfo',
  warn = 'DiagnosticWarn',
  error = 'DiagnosticError',
}

--- What each spelling of a level means
local ALIASES = {
  trace = 'trace',
  trc = 'trace',
  debug = 'debug',
  dbg = 'debug',
  info = 'info',
  inf = 'info',
  information = 'info',
  notice = 'info',
  warn = 'warn',
  warning = 'warn',
  wrn = 'warn',
  error = 'error',
  err = 'error',
  fatal = 'error',
  panic = 'error',
  critical = 'error',
  crit = 'error',
  alert = 'error',
  emerg = 'error',
  emergency = 'error',
}

--- A level as anything spells it: a word, a syslog `PRIORITY` (0-7) or a
--- pino number (10-60)
---@param value any
---@param syslog? boolean Read a number as a syslog priority
---@return DyLogLevel?
function M.level(value, syslog)
  local number = tonumber(value)
  if number then
    if syslog then
      if number <= 3 then return 'error' end
      if number == 4 then return 'warn' end
      if number <= 6 then return 'info' end
      return 'debug'
    end
    if number >= 50 then return 'error' end
    if number >= 40 then return 'warn' end
    if number >= 30 then return 'info' end
    if number >= 20 then return 'debug' end
    return 'trace'
  end
  if type(value) ~= 'string' then return nil end
  return ALIASES[value:lower()]
end

--- The first of `keys` that `tbl` has a plain value for
---@param tbl table
---@param keys string[]
---@return any
local function first(tbl, keys)
  for _, key in ipairs(keys) do
    local value = tbl[key]
    if type(value) == 'string' or type(value) == 'number' then return value end
  end
  return nil
end

local TIME_KEYS = { 'time', 'timestamp', 'ts', '@timestamp', 'datetime' }
local LEVEL_KEYS = { 'level', 'severity', 'lvl', 'loglevel', 'log.level' }
local MESSAGE_KEYS = { 'msg', 'message', 'MESSAGE', 'log', 'event' }
local ID_KEYS = {
  'request_id',
  'requestId',
  'req_id',
  'reqId',
  'x-request-id',
  'trace_id',
  'traceId',
  'correlation_id',
  'correlationId',
}

--- The pairs of a logfmt line: `level=info msg="it went" id=7`
---@param line string
---@return table<string, string>? pairs nil when the line is not logfmt
function M.logfmt(line)
  local fields, count, pos = {}, 0, 1
  while pos <= #line do
    local s, e, key = line:find('^%s*([%w_%.%-@]+)=', pos)
    if not s then break end
    pos = e + 1
    local value
    if line:sub(pos, pos) == '"' then
      local close = pos + 1
      local parts = {}
      while close <= #line do
        local char = line:sub(close, close)
        if char == '\\' and close < #line then
          table.insert(parts, line:sub(close + 1, close + 1))
          close = close + 2
        elseif char == '"' then
          break
        else
          table.insert(parts, char)
          close = close + 1
        end
      end
      value = table.concat(parts)
      pos = close + 1
    else
      local _, stop, bare = line:find('^(%S*)', pos)
      value = bare
      pos = stop + 1
    end
    fields[key] = value
    count = count + 1
  end
  if count < 2 or line:sub(pos):match('%S') then return nil end
  return fields
end

---@class DyLogRecord
---@field time? string
---@field level? DyLogLevel
---@field msg string
---@field id? string
---@field raw string The line as read
---@field json boolean Whether `raw` is a JSON object

--- Format a journal timestamp, microseconds since the epoch
---@param value any
---@return string?
local function journal_time(value)
  local micro = tonumber(value)
  if not micro then return nil end
  return os.date('%Y-%m-%dT%H:%M:%S', math.floor(micro / 1e6)) --[[@as string]]
end

--- One record of a log line
---@param line string
---@return DyLogRecord
function M.parse(line)
  if line:match('^%s*{') then
    local ok, object =
      pcall(vim.json.decode, line, { luanil = { object = true, array = true } })
    if ok and type(object) == 'table' and not vim.islist(object) then
      local journal = object.__REALTIME_TIMESTAMP ~= nil
      local level = journal and M.level(object.PRIORITY, true)
        or M.level(first(object, LEVEL_KEYS))
      local msg = first(object, MESSAGE_KEYS)
      local time = journal and journal_time(object.__REALTIME_TIMESTAMP)
        or first(object, TIME_KEYS)
      return {
        time = time and tostring(time),
        level = level,
        msg = msg and tostring(msg) or line,
        id = first(object, ID_KEYS) and tostring(first(object, ID_KEYS)),
        raw = line,
        json = true,
      }
    end
  end
  local fields = M.logfmt(line)
  if fields then
    return {
      time = first(fields, TIME_KEYS),
      level = M.level(first(fields, LEVEL_KEYS)),
      msg = first(fields, MESSAGE_KEYS) or line,
      id = first(fields, ID_KEYS),
      raw = line,
      json = false,
    }
  end
  -- Plain text: the first word that is a level, if any
  local level
  for word in line:gmatch('%a+') do
    level = ALIASES[word:lower()]
    if level and (word == word:upper() or word:match('^%u%l+$')) then break end
    level = nil
  end
  return { level = level, msg = line, raw = line, json = false }
end

--- The text of one record, as the buffer shows it
---@param record DyLogRecord
---@return string
function M.format(record)
  local parts = {}
  if record.time then table.insert(parts, record.time) end
  table.insert(parts, ('%-5s'):format((record.level or '-'):upper()))
  table.insert(parts, (record.msg:gsub('\n', '⏎')))
  if record.id then table.insert(parts, '[' .. record.id .. ']') end
  return table.concat(parts, ' ')
end

---@class DyLogFilter
---@field level? DyLogLevel Only this level and louder
---@field id? string Only this request
---@field selected? table<integer, true> Only these records, by index

--- The indices of the records `filter` lets through
---@param records DyLogRecord[]
---@param filter DyLogFilter
---@return integer[]
function M.visible(records, filter)
  local out = {}
  local floor = filter.level and RANK[filter.level]
  for index, record in ipairs(records) do
    if
      (not floor or (record.level and RANK[record.level] >= floor))
      and (not filter.id or record.id == filter.id)
      and (not filter.selected or filter.selected[index])
    then
      table.insert(out, index)
    end
  end
  return out
end

local notify = require('util.notify').titled('Logs')

---@class DyLogView
---@field title string
---@field load fun(on_lines: fun(lines: string[]?, err: string?, cut: boolean?))
---@field records DyLogRecord[]
---@field filter DyLogFilter
---@field shown integer[] Record index of each buffer line

---@type table<integer, DyLogView>
local views = {}

--- What `filter` narrows down to, said in the first line
---@param filter DyLogFilter
---@return string
local function describe(filter)
  local parts = {}
  if filter.level then table.insert(parts, filter.level .. '+') end
  if filter.id then table.insert(parts, 'request ' .. filter.id) end
  if filter.selected then table.insert(parts, 'jq') end
  return #parts > 0 and (' (' .. table.concat(parts, ', ') .. ')') or ''
end

--- Show the records of the view of `bufnr` its filter lets through
---@param bufnr integer
local function render(bufnr)
  local view = views[bufnr]
  if not view then return end
  view.shown = M.visible(view.records, view.filter)
  local lines = {
    ('%s: %d of %d records%s'):format(
      view.title,
      #view.shown,
      #view.records,
      describe(view.filter)
    ),
  }
  for _, index in ipairs(view.shown) do
    table.insert(lines, M.format(view.records[index]))
  end
  scratch.set(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  for row, index in ipairs(view.shown) do
    local record = view.records[index]
    if record.level then
      local col = record.time and #record.time + 1 or 0
      vim.api.nvim_buf_set_extmark(bufnr, ns, row, col, {
        end_col = col + 5,
        hl_group = HIGHLIGHTS[record.level],
      })
    end
  end
end

--- Read the source of the view of `bufnr` again
---@param bufnr integer
function M.reload(bufnr)
  local view = views[bufnr]
  if not view then return end
  view.load(function(lines, err, cut)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not lines then return notify(err or 'failed', vim.log.levels.ERROR) end
    if cut then
      notify(
        ('Read the first %d MiB only'):format(M.MAX_BYTES / 1024 / 1024),
        vim.log.levels.WARN
      )
    end
    if #lines > M.MAX_LINES then
      lines = vim.list_slice(lines, #lines - M.MAX_LINES + 1)
    end
    view.records = vim.tbl_map(M.parse, lines)
    -- A jq selection is of the records it was run on
    view.filter.selected = nil
    render(bufnr)
  end)
end

--- The record under the cursor of `bufnr`
---@param bufnr integer
---@return DyLogRecord?
local function current(bufnr)
  local view = views[bufnr]
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local index = view and view.shown[row]
  return index and view.records[index] or nil
end

--- Show only the records of the request under the cursor, or all of them
--- again when already narrowed to one
---@param bufnr integer
function M.request(bufnr)
  local view = views[bufnr]
  if not view then return end
  if view.filter.id then
    view.filter.id = nil
    return render(bufnr)
  end
  local record = current(bufnr)
  if not record or not record.id then
    return notify('No request id on this line', vim.log.levels.WARN)
  end
  view.filter.id = record.id
  render(bufnr)
end

--- Show only `level` and louder, asked for when not given
---@param bufnr integer
---@param level? DyLogLevel
function M.min_level(bufnr, level)
  local view = views[bufnr]
  if not view then return end
  if level then
    view.filter.level = level
    return render(bufnr)
  end
  vim.ui.select(M.LEVELS, { prompt = 'Lowest level shown' }, function(choice)
    if choice then M.min_level(bufnr, choice) end
  end)
end

--- Show only the JSON records `expr` selects with `jq`, asked for when not
--- given
---@param bufnr integer
---@param expr? string
function M.jq(bufnr, expr)
  local view = views[bufnr]
  if not view then return end
  if not expr then
    return vim.ui.input({ prompt = 'jq select(…): ' }, function(input)
      if input and input ~= '' then M.jq(bufnr, input) end
    end)
  end
  if vim.fn.executable('jq') ~= 1 then
    return notify('jq is not installed', vim.log.levels.ERROR)
  end
  -- Each record goes in wrapped with its index, and the index of each one
  -- `expr` selects comes out: `.` is the record itself, as written
  local lines = {}
  for index, record in ipairs(view.records) do
    if record.json then
      table.insert(lines, ('{"i":%d,"r":%s}'):format(index, record.raw))
    end
  end
  if #lines == 0 then
    return notify('No JSON record to run jq on', vim.log.levels.WARN)
  end
  local system = require('util.system')
  system.run({ 'jq', '-c', ('.i as $i | .r | select(%s) | $i'):format(expr) }, {
    stdin = table.concat(lines, '\n') .. '\n',
    timeout = M.TIMEOUT,
  }, function(result)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if result.code ~= 0 then
      return notify(
        'jq failed: ' .. system.failure(result, 'jq'),
        vim.log.levels.ERROR
      )
    end
    local selected = {}
    for number in (result.stdout or ''):gmatch('%d+') do
      selected[tonumber(number)] = true
    end
    view.filter.selected = selected
    render(bufnr)
  end)
end

--- Show every record again
---@param bufnr integer
function M.clear(bufnr)
  local view = views[bufnr]
  if not view then return end
  view.filter = {}
  render(bufnr)
end

--- Open a view of what `load` reads
---@param title string
---@param load fun(on_lines: fun(lines: string[]?, err: string?, cut: boolean?))
---@return integer bufnr
function M.open(title, load)
  local bufnr = scratch.open({ title .. ': loading…' }, {
    name = 'dylog://' .. title,
    filetype = 'dylog',
    sensitive = 'logs, which can hold tokens and personal data',
  })
  vim.wo.wrap = false
  views[bufnr] =
    { title = title, load = load, records = {}, filter = {}, shown = {} }
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function() views[bufnr] = nil end,
  })
  local function map(lhs, fn, desc)
    vim.keymap.set(
      'n',
      lhs,
      function() fn(bufnr) end,
      { buffer = bufnr, desc = desc .. ' (Logs)' }
    )
  end
  map('<localleader>f', M.jq, 'Filter With jq')
  map('<localleader>l', M.min_level, 'Lowest Level')
  map('<localleader>i', M.request, 'Only This Request')
  map('<localleader>c', M.clear, 'Clear Filters')
  map('<localleader>r', M.reload, 'Reload')
  M.reload(bufnr)
  return bufnr
end

--- A source that runs `command` and reads what it printed
---@param command string[]
---@return fun(on_lines: fun(lines: string[]?, err: string?, cut: boolean?))
local function from_command(command)
  return function(on_lines)
    if vim.fn.executable(command[1]) ~= 1 then
      return on_lines(nil, command[1] .. ' is not installed')
    end
    local system = require('util.system')
    -- Read as it comes and stopped at the cap: a log followed with `-f`
    -- keeps printing until the deadline
    system.run(
      command,
      { timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
      function(result)
        if result.code ~= 0 and not result.cut and not result.timed_out then
          return on_lines(
            nil,
            ('%s failed: %s'):format(
              command[1],
              system.failure(result, command[1])
            )
          )
        end
        local lines = vim.split(result.stdout or '', '\n', { trimempty = true })
        -- The last line of a cut read is half a record
        if result.cut then table.remove(lines) end
        on_lines(lines, nil, result.cut)
      end
    )
  end
end

--- The commands each source runs
---@param args string[]
---@return string[]
function M.journal_command(args)
  return vim.list_extend({
    'journalctl',
    '--output=json',
    '--no-pager',
    '--lines=' .. M.TAIL,
  }, args)
end

---@param pod string
---@param args string[]
---@return string[]
function M.kube_command(pod, args)
  return vim.list_extend({ 'kubectl', 'logs', '--tail=' .. M.TAIL, pod }, args)
end

--- `:DyLog {file}`, `:DyLog journal [{args}]`, `:DyLog kube {pod} [{args}]`
---@param args { fargs: string[] }
function M.command(args)
  local first_arg = args.fargs[1]
  local rest = vim.list_slice(args.fargs, 2)
  if not first_arg then
    return notify(
      'Give a file, `journal [args]` or `kube {pod} [args]`',
      vim.log.levels.ERROR
    )
  end
  if first_arg == 'journal' then
    return M.open(
      'journal ' .. table.concat(rest, ' '),
      from_command(M.journal_command(rest))
    )
  end
  if first_arg == 'kube' then
    if not rest[1] then
      return notify('Name the pod: :DyLog kube {pod}', vim.log.levels.ERROR)
    end
    return M.open(
      'kube ' .. table.concat(rest, ' '),
      from_command(M.kube_command(rest[1], vim.list_slice(rest, 2)))
    )
  end
  local file = vim.fn.fnamemodify(vim.fn.expand(first_arg), ':p')
  if vim.fn.filereadable(file) ~= 1 then
    return notify('Cannot read ' .. file, vim.log.levels.ERROR)
  end
  M.open(vim.fn.fnamemodify(file, ':~:.'), function(on_lines)
    local lines, err, cut = M.read_tail(file)
    if not lines then return on_lines(nil, err) end
    if cut then
      notify(
        ('Read the last %d MiB only'):format(M.MAX_BYTES / 1024 / 1024),
        vim.log.levels.WARN
      )
    end
    on_lines(lines)
  end)
end

--- The lines of the last `M.MAX_BYTES` of `file`, and whether its start was
--- left out
---
--- `readfile()` with a negative count still reads the whole file to find its
--- end: a log of a few GiB would hold the editor until it is through.
---@param file string
---@return string[]? lines
---@return string? err
---@return boolean? cut
function M.read_tail(file)
  local handle, err = io.open(file, 'rb')
  if not handle then return nil, err end
  local size = handle:seek('end')
  local cut = size > M.MAX_BYTES
  handle:seek('set', cut and size - M.MAX_BYTES or 0)
  local data = handle:read('*a') or ''
  handle:close()
  local lines = vim.split(data:gsub('\r\n', '\n'), '\n', { plain = true })
  if lines[#lines] == '' then table.remove(lines) end
  -- The first line of a cut read is the end of a record
  if cut then table.remove(lines, 1) end
  return lines, nil, cut
end

return M
