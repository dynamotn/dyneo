--- PromQL run where it is written: a rule file, a dashboard, a `.promql`
--- file
---
--- `:DyPromQL` takes the expression under the cursor -- the `expr:` of the
--- alerting or recording rule it is in, the `"expr"` of a dashboard panel,
--- the paragraph of a `.promql` file, or the lines selected -- asks the
--- Prometheus server of the clone (`git config dyneo.prometheusUrl`, else
--- `DyNeo.prometheus.url`) for its value now and over the last hour, and
--- shows each series with its labels, its value and a sparkline of the hour.
--- The server is never one a file of the repository names, and curl reads
--- any credentials from `~/.netrc`, which hands each only to its own host.
---
--- `:DyPromQL test` runs `promtool test rules` on a test file (one with
--- `rule_files:`), or `promtool check rules` on a rule file.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('PromQL')

--- Series shown of one answer
M.MAX_SERIES = 50
--- Seconds of history the sparkline covers, and the step it is read at
M.RANGE = 60 * 60
M.STEP = 60
--- Milliseconds promtool may take
M.TIMEOUT = 60 * 1000
--- Lines searched above the cursor for the rule it is in
M.SEARCH = 200

local BARS = { '▁', '▂', '▃', '▄', '▅', '▆', '▇', '█' }

--- The indent of `line`, in bytes
---@param line string
---@return integer
local function indent(line) return #(line:match('^%s*')) end

--- The value of a YAML scalar written after a key: block (`|`, `>`) lines
--- below it, or inline, unquoted
---@param lines string[]
---@param at integer 1-based line of the key
---@param key_indent integer
---@param rest string What follows the key on its line
---@return string text
---@return integer last The last line of the value
local function yaml_value(lines, at, key_indent, rest)
  -- `|`, `>-`, `|2`, each with a comment after it or not
  local style = rest:gsub('%s+#.*$', ''):match('^([|>])[%d%-+]*$')
  if not style then
    -- A quoted scalar ends at its closing quote; a comment may follow
    local quoted = rest:match('^"(.-[^\\])"%s*$')
      or rest:match('^"(.-[^\\])"%s+#')
      or rest:match('^"()"')
    if quoted then
      if type(quoted) == 'number' then return '', at end
      local ok, text = pcall(vim.json.decode, '"' .. quoted .. '"')
      return ok and text or quoted, at
    end
    quoted = rest:match("^'(.*)'%s*$") or rest:match("^'(.-)'%s+#")
    if quoted then return (quoted:gsub("''", "'")), at end
    -- A plain scalar goes on over the lines below it that are indented
    -- more, folded into one
    local parts, last = { (rest:gsub('%s+#.*$', '')) }, at
    for index = at + 1, #lines do
      local line = lines[index]
      if line:match('^%s*$') or indent(line) <= key_indent then break end
      table.insert(parts, vim.trim((line:gsub('%s+#.*$', ''))))
      last = index
    end
    return table.concat(parts, ' '), last
  end
  local body, last = {}, at
  for index = at + 1, #lines do
    local line = lines[index]
    if line:match('^%s*$') then
      table.insert(body, '')
    elseif indent(line) > key_indent then
      table.insert(body, line)
      last = index
    else
      break
    end
  end
  -- Blank lines after the last one belong to what follows
  body = vim.list_slice(body, 1, last - at)
  local common
  for _, line in ipairs(body) do
    if line ~= '' then common = math.min(common or math.huge, indent(line)) end
  end
  body = vim.tbl_map(
    function(line) return line:sub((common or 0) + 1) end,
    body
  )
  return table.concat(body, style == '|' and '\n' or ' '), last
end

--- The expression the cursor is in, at 1-based `row` of `lines`
---@param lines string[]
---@param row integer
---@param filetype? string
---@return string? expr
---@return integer? first
---@return integer? last
function M.expression(lines, row, filetype)
  -- A dashboard: `"expr": "rate(x[5m])"` on the line, or one just above
  for index = row, math.max(1, row - 5), -1 do
    local json = lines[index]:match('"expr"%s*:%s*(".-[^\\]")%s*,?%s*$')
      or lines[index]:match('"expr"%s*:%s*("")')
    if json then
      local ok, text = pcall(vim.json.decode, json)
      if ok and type(text) == 'string' and text ~= '' then
        return text, index, index
      end
    end
  end
  -- A rule: the list item the cursor is in that has an `expr:`, before or
  -- after the cursor. An item of the rule's own -- a line of a list in its
  -- annotations -- has none, and the search goes on to the one holding it.
  local below = math.huge
  for start = row, math.max(1, row - M.SEARCH), -1 do
    local lead = lines[start]:match('^(%s*)%-%s')
    if lead and #lead < below then
      below = #lead
      for index = start, #lines do
        local line = lines[index]
        if
          index > start
          and not line:match('^%s*$')
          and indent(line) <= #lead
        then
          break
        end
        local key_indent, rest = line:match('^(%s*%-?%s*)expr:%s*(.-)%s*$')
        -- `expr:` of this item, not of an item nested in it
        if key_indent and (index == start or indent(line) == #key_indent) then
          local text, last = yaml_value(lines, index, #key_indent, rest)
          if vim.trim(text) ~= '' then return vim.trim(text), index, last end
        end
      end
      if below == 0 then break end
    end
  end
  -- A `.promql` file: the paragraph of the cursor
  if filetype == 'promql' and not (lines[row] or ''):match('^%s*$') then
    local first, last = row, row
    while first > 1 and not lines[first - 1]:match('^%s*$') do
      first = first - 1
    end
    while last < #lines and not lines[last + 1]:match('^%s*$') do
      last = last + 1
    end
    local body = vim.tbl_filter(
      function(line) return not line:match('^%s*#') end,
      vim.list_slice(lines, first, last)
    )
    return vim.trim(table.concat(body, '\n')), first, last
  end
  return nil
end

--- `text` as one value of a URL query
---@param text string
---@return string
local function encode(text)
  return (
    text:gsub(
      '[^%w%-_%.~]',
      function(char) return ('%%%02X'):format(char:byte()) end
    )
  )
end

--- The labels of a series, `__name__` first: `up{job="api"}`
---@param metric table<string, string>
---@return string
function M.labels(metric)
  local keys = vim.tbl_filter(
    function(key) return key ~= '__name__' end,
    vim.tbl_keys(metric)
  )
  table.sort(keys)
  local parts = vim.tbl_map(
    function(key) return ('%s=%q'):format(key, tostring(metric[key])) end,
    keys
  )
  return (metric.__name__ or '') .. '{' .. table.concat(parts, ', ') .. '}'
end

--- `values` drawn as bars from their least to their most
---@param values number[]
---@return string
function M.spark(values)
  local low, high = math.huge, -math.huge
  for _, value in ipairs(values) do
    if value == value then
      low, high = math.min(low, value), math.max(high, value)
    end
  end
  local bars = {}
  for _, value in ipairs(values) do
    if value ~= value then
      table.insert(bars, ' ')
    elseif high == low then
      table.insert(bars, BARS[4])
    else
      local step = math.floor((value - low) / (high - low) * (#BARS - 1) + 0.5)
      table.insert(bars, BARS[step + 1])
    end
  end
  return table.concat(bars)
end

--- A sample value as a number; `NaN`, `+Inf` and the like read too
---@param text any
---@return number
local function number(text)
  if text == 'NaN' then return 0 / 0 end
  if text == '+Inf' then return math.huge end
  if text == '-Inf' then return -math.huge end
  return tonumber(text) or (0 / 0)
end

--- A value for reading: up to six significant digits
---@param text any
---@return string
local function shown(text)
  local value = number(text)
  if value ~= value or value == math.huge or value == -math.huge then
    return tostring(text)
  end
  return (('%.6g'):format(value))
end

--- The lines showing what `expr` was answered: `instant` its value now,
--- `range` its last hour, which may be missing
---@param expr string
---@param instant table The `data` of `/api/v1/query`
---@param range? table The `data` of `/api/v1/query_range`
---@param range_err? string Why there is no hour to draw
---@return string[]
function M.report(expr, instant, range, range_err)
  local lines = { '# PromQL', '', '```promql' }
  vim.list_extend(lines, vim.split(expr, '\n', { plain = true }))
  vim.list_extend(lines, { '```', '' })
  local kind, result = instant.resultType, instant.result
  if kind == 'scalar' or kind == 'string' then
    table.insert(lines, ('%s: %s'):format(kind, shown(result and result[2])))
    return lines
  end
  if type(result) ~= 'table' or #result == 0 then
    table.insert(lines, 'No series: the expression matched nothing now.')
    return lines
  end
  local history = {}
  for _, series in ipairs(type(range) == 'table' and range.result or {}) do
    history[M.labels(series.metric or {})] = vim.tbl_map(
      function(point) return number(point[2]) end,
      series.values or {}
    )
  end
  table.insert(
    lines,
    ('%d series%s, %s'):format(
      #result,
      #result > M.MAX_SERIES and (', the first %d shown'):format(M.MAX_SERIES)
        or '',
      range_err and ('no history: ' .. range_err)
        or ('the last %d minutes drawn'):format(M.RANGE / 60)
    )
  )
  table.insert(lines, '')
  for index, series in ipairs(result) do
    if index > M.MAX_SERIES then break end
    local name = M.labels(series.metric or {})
    -- A range query answers a matrix: its last sample is its value
    local value = series.value
      or (series.values and series.values[#series.values])
      or {}
    local spark = history[name] and (' ' .. M.spark(history[name])) or ''
    table.insert(
      lines,
      ('- `%s` **%s**%s'):format(name, shown(value[2]), spark)
    )
  end
  return lines
end

--- Hand `on_done` the Prometheus server of the clone of `dir`
---@param dir string
---@param on_done fun(url: string?, err: string?)
function M.server(dir, on_done)
  local default = vim.tbl_get(rawget(_G, 'DyNeo') or {}, 'prometheus', 'url')
  local http = require('util.ci_http')
  http.git_config(dir, function(values)
    local url = values.prometheusurl or default
    if not url or url == '' then
      return on_done(
        nil,
        'No Prometheus server: git config dyneo.prometheusUrl <url>, or DyNeo.prometheus.url'
      )
    end
    if not http.is_server(url) then
      return on_done(nil, 'Not a server URL: ' .. url)
    end
    on_done((url:gsub('/+$', '')))
  end)
end

--- Hand `on_done` the answer of the Prometheus API at `url`: its JSON, an
--- error included -- Prometheus answers a bad expression with a 400 whose
--- body says what is wrong with it -- or why there is none
---@param url string
---@param on_done fun(doc: table?, err: string?)
local function api(url, on_done)
  local http = require('util.ci_http')
  system.run(
    http.curl({ '--header', 'Accept: application/json', '--', url }),
    { timeout = http.TIMEOUT + 1000, max_bytes = http.MAX_BYTES },
    function(result)
      local ok, doc = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if
        not result.cut
        and ok
        and type(doc) == 'table'
        and type(doc.status) == 'string'
      then
        return on_done(doc)
      end
      if result.cut then
        return on_done(nil, 'the server answered with more than can be read')
      end
      on_done(
        nil,
        result.code ~= 0 and system.failure(result, 'curl')
          or 'the server answered with something not the Prometheus API'
      )
    end
  )
end

--- Ask the server for `expr` now and over the last hour, and show both
---@param expr string
---@param dir string Where the clone that names the server is
---@param on_done? fun() For the specs
function M.run(expr, dir, on_done)
  local function finish(msg, level)
    if msg then notify(msg, level) end
    if on_done then on_done() end
  end
  if vim.fn.executable('curl') ~= 1 then
    return finish('curl is not installed', vim.log.levels.ERROR)
  end
  M.server(dir, function(server, err)
    if not server then return finish(err, vim.log.levels.ERROR) end
    local query = encode(expr)
    api(server .. '/api/v1/query?query=' .. query, function(now, now_err)
      local data = now and now.status == 'success' and now.data
      if not data then
        return finish(
          'Prometheus: '
            .. (now and (now.error or now.errorType) or now_err or 'no answer'),
          vim.log.levels.ERROR
        )
      end
      local ends = os.time()
      api(
        ('%s/api/v1/query_range?query=%s&start=%d&end=%d&step=%d'):format(
          server,
          query,
          ends - M.RANGE,
          ends,
          M.STEP
        ),
        function(hour, hour_err)
          local range = hour and hour.status == 'success' and hour.data or nil
          local why = not range
              and (hour and (hour.error or hour.errorType) or hour_err or 'no answer')
            or nil
          require('util.scratch').open(M.report(expr, data, range, why), {
            split = 'horizontal',
            filetype = 'markdown',
          })
          finish()
        end
      )
    end)
  end)
end

--- Run the expression under the cursor, or the lines of `range`
---@param range? { line1: integer, line2: integer }
---@param on_done? fun()
function M.under_cursor(range, on_done)
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local expr
  if range then
    expr = vim.trim(
      table.concat(vim.list_slice(lines, range.line1, range.line2), '\n')
    )
  else
    expr =
      M.expression(lines, vim.api.nvim_win_get_cursor(0)[1], vim.bo.filetype)
  end
  if not expr or expr == '' then
    notify('No PromQL expression under the cursor', vim.log.levels.WARN)
    if on_done then on_done() end
    return
  end
  local file = vim.api.nvim_buf_get_name(0)
  local dir = file ~= '' and vim.fs.dirname(file) or vim.uv.cwd() --[[@as string]]
  M.run(expr, dir, on_done)
end

--- Check the rule file, or run the rule tests, of the buffer with promtool
---@param on_done? fun()
function M.test(on_done)
  local function finish(msg, level)
    notify(msg, level)
    if on_done then on_done() end
  end
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' or vim.fn.filereadable(file) ~= 1 then
    return finish('The buffer is no file on disk', vim.log.levels.WARN)
  end
  if vim.bo.modified then
    return finish(
      'Write the file first: promtool reads it from disk',
      vim.log.levels.WARN
    )
  end
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local mode
  for _, line in ipairs(lines) do
    if line:match('^rule_files:') then
      mode = 'test'
      break
    end
    if line:match('^groups:') then mode = 'check' end
  end
  if not mode then
    return finish(
      'Neither a rule file (groups:) nor a rule test (rule_files:)',
      vim.log.levels.WARN
    )
  end
  -- A test names its rule files relative to itself
  system.run(
    -- `./` before it: a file named `-x.yml` is no option
    { 'promtool', mode, 'rules', './' .. vim.fs.basename(file) },
    { cwd = vim.fs.dirname(file), timeout = M.TIMEOUT },
    function(result)
      if result.missing then
        return finish('promtool is not installed', vim.log.levels.ERROR)
      end
      local output =
        vim.trim((result.stdout or '') .. '\n' .. (result.stderr or ''))
      if result.code == 0 and not result.cut then
        return finish(
          mode == 'test' and 'Every rule test passed'
            or ('Rules valid\n' .. output)
        )
      end
      if result.timed_out or result.cut then
        return finish(system.failure(result, 'promtool'), vim.log.levels.ERROR)
      end
      require('util.scratch').open(vim.split(output, '\n', { plain = true }), {
        split = 'horizontal',
        name = 'promtool ' .. mode,
      })
      finish(
        mode == 'test' and 'Rule tests failed' or 'The rules do not load',
        vim.log.levels.ERROR
      )
    end
  )
end

M.SUBCOMMANDS = { 'test' }

--- `:[range]DyPromQL`, `:DyPromQL test`
---@param args { fargs: string[], range: integer, line1: integer, line2: integer }
function M.command(args)
  if args.fargs[1] == 'test' then return M.test() end
  if args.fargs[1] then
    return notify('Unknown subcommand: ' .. args.fargs[1], vim.log.levels.ERROR)
  end
  M.under_cursor(
    args.range > 0 and { line1 = args.line1, line2 = args.line2 } or nil
  )
end

return M
