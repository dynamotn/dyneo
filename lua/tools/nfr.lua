--- Service levels worked out: availability, downtime and load
---
--- `:DyNfr 99.9 2x99.95 rps=200 latency=150ms` reads a system as the
--- components a request passes through, one after the other: `99.9` is one
--- component up 99.9% of the time, `2x99.95` two redundant copies of one,
--- either enough. What comes out is the availability of the whole, the
--- downtime it allows a week, a month and a year (of 365.25 days, a month
--- a twelfth of it), and -- with a load -- the
--- requests it may fail a month and how many are in flight at once (Little's
--- law: rate times latency).
---
--- The same load sizes the system: `size=2KB` a request gives the bandwidth,
--- `retain=30d` the storage that keeps every request that long, and
--- `capacity=500` -- the requests a second one instance serves -- how many
--- instances it takes, at the `peak=3` times the average it must survive.
local M = {}

local notify = require('util.notify').titled('NFR')

--- Seconds in a year, leap days averaged in
local YEAR = 365.25 * 86400

--- Seconds in each period downtime is given for; a month is a twelfth of a
--- year, as SLAs reckon it
M.PERIODS = {
  { 'week', 7 * 86400 },
  { 'month', YEAR / 12 },
  { 'year', YEAR },
}

--- Seconds in one of each latency unit
local UNITS = { us = 1e-6, ms = 1e-3, s = 1 }

--- Bytes in one of each size unit, read case by case: `B` bytes, decimal
--- as bandwidth is sold or binary with `i`, and a lower-case `b` bits, so
--- `100Mb` is the 12.5 MB a link of 100 megabits carries
local BYTES = {
  B = 1,
  kB = 1e3,
  KB = 1e3,
  MB = 1e6,
  GB = 1e9,
  TB = 1e12,
  KiB = 2 ^ 10,
  MiB = 2 ^ 20,
  GiB = 2 ^ 30,
  TiB = 2 ^ 40,
  b = 1 / 8,
  kb = 1e3 / 8,
  Kb = 1e3 / 8,
  Mb = 1e6 / 8,
  Gb = 1e9 / 8,
  Tb = 1e12 / 8,
}

--- Seconds in one of each retention unit
local SPANS = { h = 3600, d = 86400, w = 7 * 86400, y = YEAR }

---@class DyNfrComponent
---@field availability number A fraction, `0.999`
---@field copies integer Redundant copies, any one of them enough

---@class DyNfrSpec
---@field components DyNfrComponent[]
---@field rps? number Requests a second
---@field latency? number Seconds a request takes
---@field size? number Bytes a request carries
---@field retain? number Seconds every request is kept
---@field retain_text? string The retention as it was written
---@field capacity? number Requests a second one instance serves
---@field peak number Times the average the peak is, `1` unless given

--- A percentage, `99.9` or `99.9%`, as a fraction, or nil when it is none
---@param text string
---@return number?
local function percent(text)
  local value = tonumber((text:gsub('%%$', '')))
  if not value or value <= 0 or value > 100 then return nil end
  return value / 100
end

--- The terms of `:DyNfr`, read
---@param terms string[]
---@return DyNfrSpec? spec
---@return string? err
function M.parse(terms)
  local spec = { components = {}, peak = 1 }
  for _, term in ipairs(terms) do
    local key, value = term:match('^(%a%w*)=(.+)$')
    local copies, level = term:match('^(%d+)[xX*](.+)$')
    if key == 'rps' then
      spec.rps = tonumber(value)
      if not spec.rps or spec.rps < 0 then
        return nil, 'Not a rate: ' .. term
      end
    -- Only the mean: Little's law with a percentile would read as the mean
    elseif key == 'latency' then
      local number, unit = value:match('^([%d%.]+)(%a*)$')
      local scale = UNITS[unit ~= '' and unit or 'ms']
      if not tonumber(number) or not scale then
        return nil, 'Not a latency: ' .. term
      end
      spec.latency = tonumber(number) * scale
    elseif key == 'size' then
      local number, unit = value:match('^([%d%.]+)(%a*)$')
      local scale = BYTES[unit ~= '' and unit or 'B']
      if not tonumber(number) or not scale then
        return nil, 'Not a size (B, KB, MB, KiB, Mb, ...): ' .. term
      end
      if tonumber(number) <= 0 then
        return nil, 'A size must be above 0: ' .. term
      end
      spec.size = tonumber(number) * scale
    elseif key == 'retain' then
      local number, unit = value:match('^([%d%.]+)(%a)$')
      if not tonumber(number) or not SPANS[unit] then
        return nil, 'Not a retention (h, d, w or y): ' .. term
      end
      if tonumber(number) <= 0 then
        return nil, 'A retention must be above 0: ' .. term
      end
      spec.retain, spec.retain_text = tonumber(number) * SPANS[unit], value
    elseif key == 'capacity' or key == 'peak' then
      local number = tonumber(value)
      if not number or number <= 0 then
        return nil, ('Not a %s: %s'):format(key, term)
      end
      spec[key] = number
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
  -- Each of these scales the load; without one it would be dropped unsaid
  if not spec.rps then
    for _, key in ipairs({ 'size', 'retain', 'capacity', 'peak' }) do
      if spec[key] and (key ~= 'peak' or spec.peak ~= 1) then
        return nil, ('%s needs the load too: add rps='):format(key)
      end
    end
  end
  if spec.rps == 0 and (spec.size or spec.capacity) then
    return nil, 'Sizing needs a load above 0: rps=0'
  end
  local sized = spec.latency or spec.size or spec.capacity
  if #spec.components == 0 and not (spec.rps and sized) then
    if spec.latency and not spec.rps then
      return nil, 'Requests in flight need the load too: add rps='
    end
    return nil,
      'Nothing to work out: give an availability, or rps with latency, size or capacity'
  end
  if spec.retain and not spec.size then
    return nil, 'A retention needs the size of a request'
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
  if seconds > 0 and seconds < 0.5 then return '< 1s' end
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

--- A fraction as a percentage, with the digits it needs: `99.95%`; below
--- 1 never rounded up to `100%`
---@param fraction number
---@return string
local function as_percent(fraction)
  local digits = 6
  if fraction < 1 then
    -- Two significant digits of what is down
    local down = (1 - fraction) * 100
    digits = math.max(digits, math.ceil(-math.log10(down)) + 1)
  end
  return (
    ('%.' .. digits .. 'f')
      :format(fraction * 100)
      :gsub('0+$', '')
      :gsub('%.$', '')
  ) .. '%'
end

--- `value` in the one of `units`, each 1000 times the one before, that it
--- reads best in, to three digits and never with an exponent
---@param value number
---@param units string[]
---@return string
local function scaled(value, units)
  local index = 1
  -- On the rounded value, so 999.7 reads `1 KB`, not `1e+03 B`
  while tonumber(('%.3g'):format(value)) >= 1000 and index < #units do
    value, index = value / 1000, index + 1
  end
  local text = ('%.3g'):format(value)
  if text:find('e') then
    text = value >= 1 and ('%.0f'):format(value) or '< 0.0001'
  end
  return ('%s %s'):format(text, units[index])
end

--- `bytes` with the unit it reads best in: `1.04 TB`
---@param bytes number
---@return string
function M.bytes(bytes)
  return scaled(bytes, { 'B', 'KB', 'MB', 'GB', 'TB', 'PB', 'EB', 'ZB' })
end

--- `bytes` a second as bits a second, as links are sold: `3.2 Mbit/s`
---@param bytes number
---@return string
function M.bits(bytes)
  return scaled(
    bytes * 8,
    { 'bit', 'kbit', 'Mbit', 'Gbit', 'Tbit', 'Pbit', 'Ebit', 'Zbit' }
  ) .. '/s'
end

--- `number` without an exponent or trailing zeros: `1200000`, `1.5`
---@param number number
---@return string
local function plain(number) return (('%.3f'):format(number):gsub('%.?0+$', '')) end

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
  elseif spec.latency then
    table.insert(lines, 'In flight: not worked out without the load, rps=')
  end
  local peak = spec.rps and spec.rps * spec.peak
  if peak and spec.peak ~= 1 then
    table.insert(lines, ('Peak %s requests a second'):format(plain(peak)))
  end
  if spec.rps and spec.size then
    local line = ('Bandwidth %s/s (%s), %s a month'):format(
      M.bytes(spec.rps * spec.size),
      M.bits(spec.rps * spec.size),
      M.bytes(spec.rps * spec.size * M.PERIODS[2][2])
    )
    if spec.peak ~= 1 then
      line = ('%s, %s/s at peak'):format(line, M.bytes(peak * spec.size))
    end
    table.insert(lines, line)
  end
  if spec.rps and spec.size and spec.retain then
    table.insert(
      lines,
      ('Storage %s to keep %s'):format(
        M.bytes(spec.rps * spec.size * spec.retain),
        spec.retain_text
      )
    )
  end
  if peak and spec.capacity then
    -- Less a hair: 1.1 * 100 / 110 is 1.0000000000000002 in floating point
    local needed = math.max(1, math.ceil(peak / spec.capacity - 1e-9))
    table.insert(
      lines,
      ('Instances %d at peak, %d to lose one (N+1)'):format(needed, needed + 1)
    )
  end
  return lines
end

--- The alerts of a service level objective: the multiwindow, multi-burn-rate
--- ones of the Google SRE workbook, each firing once `budget` of the error
--- budget of the window is spent within its `long` window, and still being
--- spent over its `short` one, which lets it stop soon after the burn does
M.SLO_ALERTS = {
  { severity = 'page', long = 3600, short = 300, budget = 0.02 },
  { severity = 'page', long = 6 * 3600, short = 1800, budget = 0.05 },
  { severity = 'ticket', long = 86400, short = 2 * 3600, budget = 0.10 },
  { severity = 'ticket', long = 3 * 86400, short = 6 * 3600, budget = 0.10 },
}

--- The service level window when none is given
M.SLO_WINDOW = 30 * 86400

--- A span as Prometheus writes a range: `5m`, `6h`, `3d`
---@param seconds number
---@return string
local function prom_span(seconds)
  for _, unit in ipairs({ { 'd', 86400 }, { 'h', 3600 }, { 'm', 60 } }) do
    if seconds % unit[2] == 0 then
      return ('%d%s'):format(seconds / unit[2], unit[1])
    end
  end
  return ('%ds'):format(seconds)
end

---@class DyNfrSlo
---@field objective number A fraction, `0.999`
---@field window number Seconds the objective is held over
---@field window_text string As it was written, `30d`

--- The terms of `:DyNfr slo`, read: an objective and `window=`
---@param terms string[]
---@return DyNfrSlo? slo
---@return string? err
function M.parse_slo(terms)
  local slo = { window = M.SLO_WINDOW, window_text = '30d' }
  for _, term in ipairs(terms) do
    local window = term:match('^window=(.+)$')
    if window then
      local number, unit = window:match('^(%d+)([hdw])$')
      if not number or tonumber(number) <= 0 then
        return nil, 'Not a window (h, d or w): ' .. term
      end
      slo.window, slo.window_text = tonumber(number) * SPANS[unit], window
    elseif slo.objective then
      return nil, 'One objective only: ' .. term
    else
      slo.objective = percent(term)
      if not slo.objective or slo.objective >= 1 then
        return nil, 'Not an objective below 100%: ' .. term
      end
    end
  end
  if not slo.objective then return nil, 'Give an objective: :DyNfr slo 99.9' end
  return slo
end

--- What `slo` allows, its burn-rate alerts, and Prometheus rules for them
---@param slo DyNfrSlo
---@return string[]
function M.slo_report(slo)
  local allowed = 1 - slo.objective
  local lines = {
    ('# SLO %s over %s'):format(as_percent(slo.objective), slo.window_text),
    '',
    ('Error budget: %s of the requests, or %s down in the window.'):format(
      as_percent(allowed),
      M.duration(allowed * slo.window)
    ),
    '',
    '| Severity | Long | Short | Burn rate | Error ratio above | Budget spent | Budget gone in |',
    '| --- | --- | --- | ---: | ---: | ---: | --- |',
  }
  local alerts, dropped, unreachable = {}, {}, {}
  for _, alert in ipairs(M.SLO_ALERTS) do
    -- The workbook's rates are for 30 days; the same share of the budget
    -- in the same time is a rate in proportion to the window
    local burn = alert.budget * slo.window / alert.long
    -- A long window past the SLO window would read history it never holds,
    -- and a rate below 1 never spends the budget at all
    local threshold = burn * allowed
    local name = ('the %s over %s'):format(
      alert.severity,
      prom_span(alert.long)
    )
    if alert.long >= slo.window or burn < 1 - 1e-9 then
      table.insert(dropped, name)
    elseif threshold >= 1 then
      -- No error ratio passes 100%: the rule would never fire
      table.insert(unreachable, name)
    else
      table.insert(
        alerts,
        { alert = alert, burn = burn, threshold = threshold }
      )
      table.insert(
        lines,
        ('| %s | %s | %s | %s | %s | %d%% | %s |'):format(
          alert.severity,
          prom_span(alert.long),
          prom_span(alert.short),
          plain(burn),
          as_percent(threshold),
          alert.budget * 100,
          M.duration(slo.window / burn)
        )
      )
    end
  end
  if #dropped > 0 then
    vim.list_extend(lines, {
      '',
      ('Left out, as it would burn under 1x over a %s window: %s.'):format(
        slo.window_text,
        table.concat(dropped, ', ')
      ),
    })
  end
  if #unreachable > 0 then
    vim.list_extend(lines, {
      '',
      ('Left out, as its line is past 100%% of errors for an objective of %s: %s.'):format(
        as_percent(slo.objective),
        table.concat(unreachable, ', ')
      ),
    })
  end
  if #alerts == 0 then
    vim.list_extend(lines, {
      '',
      'No alert holds for a window this short: alert on the error ratio itself.',
    })
    return lines
  end
  vim.list_extend(lines, {
    '',
    'Each alert fires while the error ratio is above its line over both its',
    'windows. `slo:sli_error:ratio_rate<window>` is the ratio of failed',
    'requests over a window, a recording rule of your own:',
    '',
    '```yaml',
    'groups:',
    '  - name: slo-alerts',
    '    rules:',
  })
  for _, item in ipairs(alerts) do
    local long, short = prom_span(item.alert.long), prom_span(item.alert.short)
    local threshold = ('%.6g'):format(item.threshold)
    vim.list_extend(lines, {
      ('      - alert: ErrorBudgetBurn%s'):format(long),
      '        expr: |',
      ('          slo:sli_error:ratio_rate%s > %s'):format(long, threshold),
      ('          and slo:sli_error:ratio_rate%s > %s'):format(
        short,
        threshold
      ),
      '        labels:',
      ('          severity: %s'):format(item.alert.severity),
      '        annotations:',
      ('          summary: Error budget burning %sx over %s'):format(
        plain(item.burn),
        long
      ),
    })
  end
  table.insert(lines, '```')
  return lines
end

--- `:DyNfr {term}...`, asking for the terms when none are given;
--- `:DyNfr slo {objective} [window=30d]`
---@param args { fargs: string[] }
function M.command(args)
  if args.fargs[1] == 'slo' then
    local slo, err = M.parse_slo(vim.list_slice(args.fargs, 2))
    if not slo then return notify(err, vim.log.levels.ERROR) end
    require('util.scratch').open(M.slo_report(slo), { filetype = 'markdown' })
    return
  end
  local function run(terms)
    local spec, err = M.parse(terms)
    if not spec then return notify(err, vim.log.levels.ERROR) end
    notify(table.concat(M.report(spec), '\n'))
  end
  if #args.fargs > 0 then return run(args.fargs) end
  vim.ui.input(
    { prompt = 'Terms (99.9 2x99.95 rps=… size=… capacity=…): ' },
    function(input)
      if input and vim.trim(input) ~= '' then
        run(vim.split(vim.trim(input), '%s+'))
      end
    end
  )
end

return M
