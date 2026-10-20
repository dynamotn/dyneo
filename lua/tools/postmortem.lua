--- A blameless postmortem, kept as a decision record, its timeline gathered
---
--- `:DyPostmortem new [{title}]` asks when the incident started and ended,
--- then writes, as a new record of `tools.adr`, the sections a postmortem
--- answers -- summary, impact, timeline, root cause, contributing factors,
--- what went well and wrong, action items -- with the timeline filled in
--- from what this machine can see of the window: the commits of the project
--- (`git log`), and the events of the current Kubernetes context
--- (`kubectl get events`). A source that cannot be read is named, not left
--- out silently. `:DyPostmortem` reads the postmortem open (or the
--- project's latest) the way `:DyWar` reads a review: its action items
--- still open, in the quickfix list.
---
--- What is gathered stays in the file written here; nothing leaves the
--- machine but the `kubectl` request to the cluster already in use.
local M = {}

local adr = require('tools.adr')
local war = require('tools.war')
local system = require('util.system')
local notify = require('util.notify').titled('Postmortem')

--- The title every postmortem starts with; what happened follows it
M.TITLE = 'Postmortem'

--- Milliseconds each source may take
M.TIMEOUT = 20 * 1000
--- Entries of one source in the timeline
M.MAX_ENTRIES = 200
--- Bytes read of one source
M.MAX_BYTES = 8 * 1024 * 1024

--- A postmortem, as `war.report` reads it: only its action items count
---@type DyChecklistKind
M.KIND = {
  pattern = '^' .. vim.pesc(M.TITLE) .. ': %S',
  label = 'Postmortem',
  noun = 'postmortem',
  command = ':DyPostmortem new',
  sections = { { 'Action items', {} } },
}

--- Seconds since the epoch of `text`, a local time: `2026-10-20 13:05`, or
--- `13:05` today; nil for anything else
---@param text string
---@param now? integer
---@return integer?
function M.parse_time(text, now)
  text = vim.trim(text)
  local year, month, day, hour, minute =
    text:match('^(%d%d%d%d)%-(%d%d)%-(%d%d)[ T](%d%d?):(%d%d)$')
  if not year then
    hour, minute = text:match('^(%d%d?):(%d%d)$')
    if not hour then return nil end
    local today = os.date('*t', now or os.time()) --[[@as osdate]]
    year, month, day = today.year, today.month, today.day
  end
  local fields = {
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = 0,
  }
  if
    fields.month < 1
    or fields.month > 12
    or fields.day < 1
    or fields.day > 31
    or fields.hour > 23
    or fields.min > 59
  then
    return nil
  end
  return os.time(fields)
end

---@class DyPostmortemEntry
---@field time integer Seconds since the epoch
---@field source string `git`, `kubernetes`
---@field text string

--- `text` as one cell of a Markdown table: one line, no column break
---@param text string
---@return string
local function cell(text) return (text:gsub('[\r\n]+', ' '):gsub('|', '\\|')) end

--- Hand `on_done` the commits of `root` made within the window
---@param root string
---@param since integer
---@param till integer
---@param on_done fun(entries: DyPostmortemEntry[]?, err: string?)
function M.git(root, since, till, on_done)
  system.run(
    {
      'git',
      'log',
      ('--since=@%d'):format(since),
      ('--until=@%d'):format(till),
      ('--max-count=%d'):format(M.MAX_ENTRIES),
      '--date=unix',
      '--pretty=format:%cd%x09%h%x09%an%x09%s',
    },
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      if result.code ~= 0 or result.cut then
        return on_done(nil, system.failure(result, 'git log'))
      end
      local entries = {}
      for line in (result.stdout or ''):gmatch('[^\n]+') do
        local time, hash, author, subject =
          line:match('^(%d+)\t(%S+)\t([^\t]*)\t(.*)$')
        if time then
          table.insert(entries, {
            time = tonumber(time),
            source = 'git',
            text = ('`%s` %s (%s)'):format(hash, subject, author),
          })
        end
      end
      on_done(entries)
    end
  )
end

--- Hand `on_done` the events of the current Kubernetes context within the
--- window, warnings first when there are more than `M.MAX_ENTRIES`
---@param since integer
---@param till integer
---@param on_done fun(entries: DyPostmortemEntry[]?, err: string?)
function M.kube(since, till, on_done)
  system.run(
    { 'kubectl', 'get', 'events', '--all-namespaces', '--output=json' },
    { timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES, detach = true },
    function(result)
      if result.missing then return on_done(nil, 'kubectl is not installed') end
      if result.code ~= 0 or result.cut then
        return on_done(nil, system.failure(result, 'kubectl'))
      end
      local ok, data = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(data) ~= 'table' then
        return on_done(nil, 'kubectl answered with something not JSON')
      end
      local epoch = require('tools.mason-quarantine').epoch
      local entries = {}
      for _, event in ipairs(type(data.items) == 'table' and data.items or {}) do
        local time = epoch(event.lastTimestamp)
          or epoch(event.eventTime)
          or epoch(event.firstTimestamp)
        if time and time >= since and time <= till then
          local object = event.involvedObject or {}
          table.insert(entries, {
            time = time,
            source = 'kubernetes',
            warning = event.type == 'Warning',
            text = ('%s%s/%s/%s %s: %s'):format(
              event.type == 'Warning' and '**Warning** ' or '',
              object.namespace or (event.metadata or {}).namespace or '-',
              object.kind or '?',
              object.name or '?',
              event.reason or '?',
              event.message or ''
            ),
          })
        end
      end
      if #entries > M.MAX_ENTRIES then
        table.sort(entries, function(a, b)
          if a.warning ~= b.warning then return a.warning end
          return a.time < b.time
        end)
        entries = vim.list_slice(entries, 1, M.MAX_ENTRIES)
      end
      on_done(entries)
    end
  )
end

--- The lines of the postmortem of `title`, numbered `number`
---@param number integer
---@param date string
---@param title string
---@param since integer
---@param till integer
---@param entries DyPostmortemEntry[]
---@param skipped string[] Each source left out, and why
---@return string[]
function M.template(number, date, title, since, till, entries, skipped)
  local function utc(time) return os.date('!%Y-%m-%d %H:%M:%S', time) end
  local lines = {
    ('# %d. %s: %s'):format(number, M.TITLE, title),
    '',
    'Date: ' .. date,
    '',
    '## Status',
    '',
    'Proposed',
    '',
    '## Context',
    '',
    ('From %s to %s UTC. Blameless: what the system let happen, not who.'):format(
      utc(since),
      utc(till)
    ),
    '',
    '### Summary',
    '',
    'What happened, in two sentences.',
    '',
    '### Impact',
    '',
    'Who was affected, how badly and for how long; the error budget it spent',
    '(`:DyNfr slo`).',
    '',
    '### Timeline',
    '',
    '| Time (UTC) | Source | What |',
    '| --- | --- | --- |',
  }
  table.sort(entries, function(a, b) return a.time < b.time end)
  for _, entry in ipairs(entries) do
    table.insert(
      lines,
      ('| %s | %s | %s |'):format(
        utc(entry.time),
        entry.source,
        cell(entry.text)
      )
    )
  end
  table.insert(lines, '')
  if #entries == 0 then
    table.insert(lines, 'Nothing was found in the window.')
  end
  for _, reason in ipairs(skipped) do
    table.insert(lines, '- Not read: ' .. reason)
  end
  vim.list_extend(lines, {
    'Add when it was detected, who was paged, what was tried and when it',
    'recovered.',
    '',
    '## Root cause',
    '',
    '## Contributing factors',
    '',
    '## What went well',
    '',
    '## What went wrong',
    '',
    '## Action items',
    '',
    '- [ ] What, who owns it, by when',
    '',
    '## Consequences',
    '',
    'The decisions it leads to, as records of their own (`:DyAdr new`).',
  })
  return lines
end

--- Gather the timeline of the window and write the postmortem of `title`
---@param title string
---@param since integer
---@param till integer
---@param on_done? fun(file: string?) For the specs
function M.write(title, since, till, on_done)
  local root = war.root()
  local dir, err = adr.dir(root)
  if not dir then
    notify(err, vim.log.levels.ERROR)
    if on_done then on_done(nil) end
    return
  end
  notify('Gathering the timeline…')
  local entries, skipped = {}, {}
  local sources = {
    { 'git', function(cb) M.git(root, since, till, cb) end },
    { 'kubernetes', function(cb) M.kube(since, till, cb) end },
  }
  system.each(sources, #sources, function(source, done)
    source[2](function(found, why)
      if found then
        vim.list_extend(entries, found)
        if #found >= M.MAX_ENTRIES then
          table.insert(
            skipped,
            ('%s past the first %d entries'):format(source[1], M.MAX_ENTRIES)
          )
        end
      else
        table.insert(
          skipped,
          ('%s, %s'):format(source[1], why or 'no reason given')
        )
      end
      done()
    end)
  end, function()
    table.sort(skipped)
    local date = os.date('%Y-%m-%d') --[[@as string]]
    local record, why = adr.create(dir, ('%s: %s'):format(M.TITLE, title))
    if not record then
      notify(why, vim.log.levels.ERROR)
      if on_done then on_done(nil) end
      return
    end
    vim.fn.writefile(
      M.template(record.number, date, title, since, till, entries, skipped),
      record.file
    )
    vim.cmd.edit(vim.fn.fnameescape(record.file))
    notify(
      ('Postmortem %d written, %d timeline entries%s'):format(
        record.number,
        #entries,
        #skipped > 0 and ('; not read: ' .. table.concat(skipped, '; ')) or ''
      ),
      #skipped > 0 and vim.log.levels.WARN or nil
    )
    if on_done then on_done(record.file) end
  end)
end

--- Ask for what is missing of `title` and the window, then write it
---@param title? string
function M.new(title)
  local function ask_window(name)
    vim.ui.input(
      { prompt = 'Started (YYYY-MM-DD HH:MM, or HH:MM today): ' },
      function(start)
        if not start or vim.trim(start) == '' then return end
        local since = M.parse_time(start)
        if not since then
          return notify('Not a time: ' .. start, vim.log.levels.ERROR)
        end
        vim.ui.input({ prompt = 'Ended (empty for now): ' }, function(finish)
          if finish == nil then return end
          local till = vim.trim(finish) == '' and os.time()
            or M.parse_time(finish)
          if not till then
            return notify('Not a time: ' .. finish, vim.log.levels.ERROR)
          end
          if till <= since then
            return notify('It ended before it started', vim.log.levels.ERROR)
          end
          M.write(name, since, till)
        end)
      end
    )
  end
  if title and title ~= '' then return ask_window(title) end
  vim.ui.input({ prompt = 'What happened: ' }, function(input)
    if input and vim.trim(input) ~= '' then ask_window(vim.trim(input)) end
  end)
end

--- `:DyPostmortem [new [{title}]]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return war.report(M.KIND) end
  if sub == 'new' then
    return M.new(table.concat(vim.list_slice(args.fargs, 2), ' '))
  end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
