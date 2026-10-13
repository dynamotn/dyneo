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

--- The checklist items of `lines`, each with the pillar it is under
---@param lines string[]
---@return DyWarItem[]
function M.items(lines)
  local items, pillar = {}, nil
  for lnum, line in ipairs(lines) do
    pillar = line:match('^##%s+(.-)%s*$') or pillar
    local mark, text = line:match('^%s*[-*]%s+%[(.)%]%s+(.*)$')
    if mark and pillar then
      table.insert(items, {
        pillar = pillar,
        text = text,
        lnum = lnum,
        done = mark ~= ' ',
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
local function root()
  return vim.fs.root(0, { '.git', '.adr-dir' }) or vim.uv.cwd() --[[@as string]]
end

--- Write a review and open it
function M.new()
  local date = os.date('%Y-%m-%d') --[[@as string]]
  local record = adr.create(adr.dir(root()), ('%s %s'):format(M.TITLE, date))
  vim.fn.writefile(M.template(record.number, date), record.file)
  vim.cmd.edit(vim.fn.fnameescape(record.file))
  notify(('Review %d written: tick what holds'):format(record.number))
end

--- The file of the review to read: the buffer's when it is one, else the
--- latest of the project
---@return string? file
local function review_file()
  local file = vim.api.nvim_buf_get_name(0)
  local first = vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ''
  if file ~= '' and first:find(M.TITLE, 1, true) then return file end
  local latest
  for _, record in ipairs(adr.list(adr.dir(root()))) do
    if record.title:find(M.TITLE, 1, true) == 1 then latest = record.file end
  end
  return latest
end

--- Say how far the review got, and list its open questions
function M.check()
  local file = review_file()
  if not file then
    return notify('No review yet: `:DyWar new` writes one', vim.log.levels.WARN)
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
  local items = M.items(lines)
  local open = vim.tbl_filter(function(item) return not item.done end, items)
  local summary = table.concat(M.summary(items), '\n')
  if #open == 0 then return notify('Every question holds\n' .. summary) end
  vim.fn.setqflist({}, ' ', {
    title = 'Well-Architected: open questions',
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
  notify(
    ('%d of %d questions open\n%s'):format(#open, #items, summary),
    vim.log.levels.WARN
  )
end

--- `:DyWar [new]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.check() end
  if sub == 'new' then return M.new() end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
