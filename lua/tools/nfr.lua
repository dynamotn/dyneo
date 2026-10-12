--- Service levels worked out: availability, downtime and load
---
--- `:DyNfr 99.9 2x99.95 rps=200 latency=150ms` reads a system as the
--- components a request passes through, one after the other: `99.9` is one
--- component up 99.9% of the time, `2x99.95` two redundant copies of one,
--- either enough. What comes out is the availability of the whole, the
--- downtime it allows a week, a month and a year, and -- with a load -- the
--- requests it may fail a month and how many are in flight at once (Little's
--- law: rate times latency).
local M = {}

local notify = require('util.notify').titled('NFR')

--- Seconds in each period downtime is given for; a month is 30 days
M.PERIODS = {
  { 'week', 7 * 86400 },
  { 'month', 30 * 86400 },
  { 'year', 365 * 86400 },
}

--- Seconds in one of each latency unit
local UNITS = { us = 1e-6, ms = 1e-3, s = 1 }

---@class DyNfrComponent
---@field availability number A fraction, `0.999`
---@field copies integer Redundant copies, any one of them enough

---@class DyNfrSpec
---@field components DyNfrComponent[]
---@field rps? number Requests a second
---@field latency? number Seconds a request takes

--- A percentage as a fraction, or nil when it is none
---@param text string
---@return number?
local function percent(text)
  local value = tonumber(text)
  if not value or value <= 0 or value > 100 then return nil end
  return value / 100
end

--- The terms of `:DyNfr`, read
---@param terms string[]
---@return DyNfrSpec? spec
---@return string? err
function M.parse(terms)
  local spec = { components = {} }
  for _, term in ipairs(terms) do
    local key, value = term:match('^(%a%w*)=(.+)$')
    local copies, level = term:match('^(%d+)[xX*](.+)$')
    if key == 'rps' then
      spec.rps = tonumber(value)
      if not spec.rps or spec.rps < 0 then
        return nil, 'Not a rate: ' .. term
      end
    elseif key == 'latency' or key == 'p99' or key == 'p50' then
      local number, unit = value:match('^([%d%.]+)(%a*)$')
      local scale = UNITS[unit ~= '' and unit or 'ms']
      if not tonumber(number) or not scale then
        return nil, 'Not a latency: ' .. term
      end
      spec.latency = tonumber(number) * scale
    elseif key then
      return nil, 'Unknown term: ' .. term
    else
      local fraction = percent(level or term)
      local count = tonumber(copies or 1)
      if not fraction or count < 1 then
        return nil, 'Not an availability: ' .. term
      end
      table.insert(
        spec.components,
        { availability = fraction, copies = math.floor(count) }
      )
    end
  end
  if #spec.components == 0 and not (spec.rps and spec.latency) then
    return nil, 'Nothing to work out: give an availability, or rps and latency'
  end
  return spec
end

--- The availability of `components` in a row, each with its copies
---@param components DyNfrComponent[]
---@return number
function M.availability(components)
  local up = 1
  for _, component in ipairs(components) do
    up = up * (1 - (1 - component.availability) ^ component.copies)
  end
  return up
end

--- `seconds` the way a person says it: `43m 12s`, `8h 45m`, `1d 2h`
---@param seconds number
---@return string
function M.duration(seconds)
  seconds = math.floor(seconds + 0.5)
  if seconds < 60 then return seconds .. 's' end
  local parts = {}
  for _, unit in ipairs({ { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 } }) do
    local count = math.floor(seconds / unit[2])
    if count > 0 then
      table.insert(parts, count .. unit[1])
      seconds = seconds - count * unit[2]
    end
    if #parts == 2 then break end
  end
  if #parts < 2 and seconds > 0 then table.insert(parts, seconds .. 's') end
  return table.concat(parts, ' ')
end

--- A fraction as a percentage, with the digits it needs: `99.95%`
---@param fraction number
---@return string
local function as_percent(fraction)
  return (('%.6f'):format(fraction * 100):gsub('0+$', ''):gsub('%.$', ''))
    .. '%'
end

--- What `spec` works out to, a line each
---@param spec DyNfrSpec
---@return string[]
function M.report(spec)
  local lines = {}
  if #spec.components > 0 then
    local up = M.availability(spec.components)
    table.insert(lines, 'Availability ' .. as_percent(up))
    for _, period in ipairs(M.PERIODS) do
      table.insert(
        lines,
        ('Down %s a %s'):format(M.duration((1 - up) * period[2]), period[1])
      )
    end
    if spec.rps then
      table.insert(
        lines,
        ('Error budget %d requests a month'):format(
          math.floor(spec.rps * M.PERIODS[2][2] * (1 - up) + 0.5)
        )
      )
    end
  end
  if spec.rps and spec.latency then
    table.insert(
      lines,
      ('In flight %.1f requests at once'):format(spec.rps * spec.latency)
    )
  end
  return lines
end

--- `:DyNfr {term}...`, asking for the terms when none are given
---@param args { fargs: string[] }
function M.command(args)
  local function run(terms)
    local spec, err = M.parse(terms)
    if not spec then return notify(err, vim.log.levels.ERROR) end
    notify(table.concat(M.report(spec), '\n'))
  end
  if #args.fargs > 0 then return run(args.fargs) end
  vim.ui.input(
    { prompt = 'Components (99.9 2x99.95 rps=…): ' },
    function(input)
      if input and vim.trim(input) ~= '' then
        run(vim.split(vim.trim(input), '%s+'))
      end
    end
  )
end

return M
