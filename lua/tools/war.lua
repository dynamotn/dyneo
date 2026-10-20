--- A Well-Architected review, kept as a decision record
---
--- `:DyWar new` writes the questions of the six pillars -- operational
--- excellence, security, reliability, performance efficiency, cost and
--- sustainability -- as a checklist in a new record of `tools.adr`, so the
--- review is numbered, dated and listed beside the decisions it leads to.
--- `:DyWar` reads the review open (or the project's latest), says how far
--- each pillar got, and lists the questions still open in the quickfix list.
local M = {}

local adr = require('tools.adr')
local notify = require('util.notify').titled('Well-Architected')

--- The title every review starts with; the date follows it
M.TITLE = 'Well-Architected review'

--- The pillars and their questions, after the AWS, Azure and Google
--- frameworks, which ask the same things in their own words
M.PILLARS = {
  {
    'Operational excellence',
    {
      'Deploys are automated, small and reversible',
      'Every service has runbooks for its known failures',
      'Logs, metrics and traces answer what a request did',
      'Alerts page on symptoms users feel, not on causes',
    },
  },
  {
    'Security',
    {
      'Identities have least privilege, and no long-lived keys',
      'Data is encrypted in transit and at rest',
      'Secrets live in a vault, never in code or images',
      'Dependencies and images are scanned, and patched on a schedule',
    },
  },
  {
    'Reliability',
    {
      'Availability and latency objectives are written down',
      'No single zone, instance or person is a single point of failure',
      'Backups are restored on a schedule, not only taken',
      'Load is shed or queued before it takes the system down',
    },
  },
  {
    'Performance efficiency',
    {
      'Capacity is load tested against the expected peak',
      'Scaling is automatic, and its limits are known',
      'Hot paths are cached, and caches invalidated on purpose',
    },
  },
  {
    'Cost optimization',
    {
      'Every resource has an owner and a cost tag',
      'Spend is reviewed each month against a budget with alerts',
      'Idle and oversized resources are found and removed',
      'Steady load runs on commitments, bursty load on spot or serverless',
    },
  },
  {
    'Sustainability',
    {
      'Regions are chosen with their carbon intensity in mind',
      'Environments that are not used are stopped out of hours',
      'Data has a retention period, and is deleted after it',
    },
  },
}

--- The lines of a review numbered `number`
---@param number integer
---@param date string
---@return string[]
function M.template(number, date)
  local lines = {
    ('# %d. %s %s'):format(number, M.TITLE, date),
    '',
    'Date: ' .. date,
    '',
    '## Status',
    '',
    'Proposed',
    '',
    '## Context',
    '',
    'The workload reviewed, its owners, and what changed since the last review.',
  }
  for _, pillar in ipairs(M.PILLARS) do
    vim.list_extend(lines, { '', '## ' .. pillar[1], '' })
    for _, question in ipairs(pillar[2]) do
      table.insert(lines, '- [ ] ' .. question)
    end
  end
  vim.list_extend(lines, {
    '',
    '## Consequences',
    '',
    'What is fixed first, and the decisions it calls for.',
  })
  return lines
end

---@class DyWarItem
---@field pillar string
---@field text string
---@field lnum integer
---@field done boolean

--- The checklist items of `lines` under one of `sections` (`M.PILLARS`
--- unless given), each with its section; another `##` heading
--- (`Consequences`) ends the section above
---@param lines string[]
---@param sections? [string, string[]][]
---@return DyWarItem[]
function M.items(lines, sections)
  local names = {}
  for _, pillar in ipairs(sections or M.PILLARS) do
    names[pillar[1]] = true
  end
  local items, pillar = {}, nil
  for lnum, line in ipairs(lines) do
    local heading = line:match('^##%s+(.-)%s*$')
    if heading then pillar = names[heading] and heading or nil end
    local mark, text = line:match('^%s*[-*]%s+%[(.)%]%s+(.*)$')
    if mark and pillar then
      table.insert(items, {
        pillar = pillar,
        text = text,
        lnum = lnum,
        -- Only a tick: `[~]` and the like are still open
        done = mark == 'x' or mark == 'X',
      })
    end
  end
  return items
end

--- How far each pillar got, in the order they come: `Security 2/4`
---@param items DyWarItem[]
---@return string[]
function M.summary(items)
  local order, counts = {}, {}
  for _, item in ipairs(items) do
    if not counts[item.pillar] then
      table.insert(order, item.pillar)
      counts[item.pillar] = { done = 0, total = 0 }
    end
    local count = counts[item.pillar]
    count.total = count.total + 1
    if item.done then count.done = count.done + 1 end
  end
  return vim.tbl_map(
    function(pillar)
      return ('%s %d/%d'):format(
        pillar,
        counts[pillar].done,
        counts[pillar].total
      )
    end,
    order
  )
end

--- The project root of the current buffer
---@return string
function M.root()
  return vim.fs.root(0, { '.git', '.adr-dir' }) or vim.uv.cwd() --[[@as string]]
end

--- Write a review and open it
function M.new()
  local date = os.date('%Y-%m-%d') --[[@as string]]
  local dir, err = adr.dir(M.root())
  if not dir then return notify(err, vim.log.levels.ERROR) end
  local record, why = adr.create(dir, ('%s %s'):format(M.TITLE, date))
  if not record then return notify(why, vim.log.levels.ERROR) end
  vim.fn.writefile(M.template(record.number, date), record.file)
  vim.cmd.edit(vim.fn.fnameescape(record.file))
  notify(('Review %d written: tick what holds'):format(record.number))
end

--- A kind of checklist kept as a decision record
---@class DyChecklistKind
---@field pattern string A Lua pattern the whole title of a record matches
---@field label string The title of its notifications and quickfix list
---@field noun string What one is called: `review`
---@field command string What writes one
---@field sections [string, string[]][] Its headings and their questions

--- The Well-Architected review, as `report` reads it
---@type DyChecklistKind
M.KIND = {
  pattern = '^' .. vim.pesc(M.TITLE) .. ' %d%d%d%d%-%d%d%-%d%d$',
  label = 'Well-Architected',
  noun = 'review',
  command = ':DyWar new',
  sections = M.PILLARS,
}

--- Whether `record` is one of `kind`: its `# N. title` heading, not a
--- mention elsewhere or a title that only starts alike, matches the kind
---@param kind DyChecklistKind
---@param record? DyAdr
---@return boolean
local function is_kind(kind, record)
  return record ~= nil and record.title:match(kind.pattern) ~= nil
end

--- The record of `kind` to read: the buffer's when it is one, else the
--- latest of the project
---@param kind DyChecklistKind
---@return string? file
---@return string? err Why the project's records cannot be read
local function record_file(kind)
  local file = vim.api.nvim_buf_get_name(0)
  local buffer = file ~= ''
    and adr.parse(vim.api.nvim_buf_get_lines(0, 0, 40, false), file)
  if buffer and is_kind(kind, buffer) then return file end
  local dir, err = adr.dir(M.root())
  if not dir then return nil, err end
  local latest
  for _, record in ipairs(adr.list(dir)) do
    if is_kind(kind, record) then latest = record.file end
  end
  return latest
end

--- Say how far the record of `kind` got, and list its open questions
---@param kind DyChecklistKind
function M.report(kind)
  local say = require('util.notify').titled(kind.label)
  local file, err = record_file(kind)
  if err then return say(err, vim.log.levels.ERROR) end
  if not file then
    return say(
      ('No %s yet: `%s` writes one'):format(kind.noun, kind.command),
      vim.log.levels.WARN
    )
  end
  -- By name, not `bufnr(file)`: that is a pattern, which a loaded
  -- `<review>.md.orig` matches too
  local lines
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if
      vim.api.nvim_buf_is_loaded(bufnr)
      and vim.api.nvim_buf_get_name(bufnr) == file
    then
      lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    end
  end
  lines = lines or vim.fn.readfile(file)
  local items = M.items(lines, kind.sections)
  local open = vim.tbl_filter(function(item) return not item.done end, items)
  -- A record with nothing to tick has not been reviewed, not passed
  if #items == 0 then
    return say(
      ('No checklist in %s'):format(vim.fn.fnamemodify(file, ':~:.')),
      vim.log.levels.WARN
    )
  end
  local summary = table.concat(M.summary(items), '\n')
  if #open == 0 then return say('Every question holds\n' .. summary) end
  vim.fn.setqflist({}, ' ', {
    title = kind.label .. ': open questions',
    items = vim.tbl_map(
      function(item)
        return {
          filename = file,
          lnum = item.lnum,
          text = ('%s: %s'):format(item.pillar, item.text),
        }
      end,
      open
    ),
  })
  vim.cmd('botright copen')
  say(
    ('%d of %d questions open\n%s'):format(#open, #items, summary),
    vim.log.levels.WARN
  )
end

--- Say how far the latest review got, and list its open questions
function M.check() return M.report(M.KIND) end

--- `:DyWar [new]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.check() end
  if sub == 'new' then return M.new() end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
