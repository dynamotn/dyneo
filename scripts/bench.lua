-- Benchmark how fast this configuration starts, and write the numbers into
-- the Benchmark section of README.md.
--
--   nvim --clean --headless -l scripts/bench.lua
--
-- Each scenario is started a number of times in a throwaway Neovim pointed at
-- this tree (as check-startup.sh does), with `--startuptime` recording where
-- the time went. The section between the `bench:start` and `bench:end`
-- markers is then regenerated.
--
-- Timings are noisy, and a hook that rewrites the README on every commit
-- would fail every commit. So the section is only rewritten when a scenario
-- moved by more than a threshold, or when asked to.
--
-- Environment:
--   BENCH_RUNS=10       measured runs per scenario, after one warm-up run
--   BENCH_THRESHOLD=20  percent a median must move before the README changes
--   BENCH_FORCE=1       rewrite the section whatever the numbers say

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local readme = root .. '/README.md'
local wrap = dofile(root .. '/scripts/lib/wrap.lua')
local runs = tonumber(vim.env.BENCH_RUNS) or 10
local threshold = tonumber(vim.env.BENCH_THRESHOLD) or 20
local force = vim.env.BENCH_FORCE == '1'

local start_marker = '<!-- bench:start -->'
local end_marker = '<!-- bench:end -->'

-- Files of this repository, so every tool they call for is one this
-- repository already needs and nothing is written anywhere.
---@type { cmd: string, args: string[] }[]
local scenarios = {
  { cmd = 'nvim --headless +q', args = {} },
  { cmd = 'nvim --headless README.md +q', args = { 'README.md' } },
  { cmd = 'nvim --headless init.lua +q', args = { 'init.lua' } },
}

local workdir, config = dofile(root .. '/scripts/lib/workdir.lua').config(root)

---@class bench.Run
---@field startup number `--- NVIM STARTED ---` clock, in ms
---@field wall number process lifetime, in ms
---@field steps table<string, number> time per step, in ms

--- Short name for a `--startuptime` step, or nil for one not worth listing
---@param text string
---@return string?
local function step_name(text)
  local module = text:match("^require%('(.-)'%)$")
  if module then return module end
  local file = text:match('^sourcing (/.+)$')
  if file then
    local plugin, rest = file:match('/lazy/([^/]+)/(.+)$')
    return plugin and (plugin .. '/' .. vim.fn.fnamemodify(rest, ':t'))
      or vim.fn.fnamemodify(file, ':t')
  end
  -- Scripts an autocommand sources through `nvim_exec2()`: the scripts
  -- themselves are listed, and this wrapper only counts them twice.
  if text:match('^sourcing ') then return nil end
  return text
end

---@param steps table<string, number>
---@param text string
---@param ms number
local function add_step(steps, text, ms)
  local name = step_name(text)
  if name then steps[name] = (steps[name] or 0) + ms end
end

---@param log string path of a `--startuptime` log
---@return number?, table<string, number>
local function parse_log(log)
  local startup, steps = nil, {}
  for line in io.lines(log) do
    local clock, elapsed, text = line:match('^(%d+%.%d+)%s+(%d+%.%d+):%s+(.+)$')
    if clock then
      if text == '--- NVIM STARTED ---' then
        startup = tonumber(clock)
      elseif not text:match('^%-%-%-') then
        add_step(steps, text, tonumber(elapsed) --[[@as number]])
      end
    else
      -- `clock  self+sourced  self: text`, for scripts and modules
      local total
      clock, total, _, text =
        line:match('^(%d+%.%d+)%s+(%d+%.%d+)%s+(%d+%.%d+):%s+(.+)$')
      if clock then
        add_step(steps, text, tonumber(total) --[[@as number]])
      end
    end
  end
  return startup, steps
end

---@param scenario { cmd: string, args: string[] }
---@return bench.Run
local function run_once(scenario)
  local log = workdir .. '/startuptime.log'
  vim.fn.delete(log)
  local cmd = { 'nvim', '--headless', '-i', 'NONE', '--startuptime', log }
  vim.list_extend(cmd, scenario.args)
  table.insert(cmd, '+q')
  local started = vim.uv.hrtime()
  local result = vim
    .system(cmd, {
      cwd = root,
      env = { XDG_CONFIG_HOME = config },
      text = true,
    })
    -- A configuration that hangs on start must fail the hook, not hold it
    :wait(
      60000
    )
  local wall = (vim.uv.hrtime() - started) / 1e6
  if result.code ~= 0 then
    error(
      ('%s exited with %d:\n%s'):format(
        scenario.cmd,
        result.code,
        result.stderr
      )
    )
  end
  local startup, steps = parse_log(log)
  if not startup then error(scenario.cmd .. ': no startup time recorded') end
  return { startup = startup, wall = wall, steps = steps }
end

---@param values number[]
---@return { median: number, mean: number, sd: number, min: number, max: number }
local function stats(values)
  local sum, min, max = 0, math.huge, -math.huge
  for _, v in ipairs(values) do
    sum = sum + v
    min, max = math.min(min, v), math.max(max, v)
  end
  local mean = sum / #values
  local sq = 0
  for _, v in ipairs(values) do
    sq = sq + (v - mean) ^ 2
  end
  local sd = #values > 1 and math.sqrt(sq / (#values - 1)) or 0
  -- The median is what the README is compared on: a run the machine chose
  -- to be busy for moves the mean a lot and the median hardly at all.
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local mid = math.floor(#sorted / 2)
  local median = #sorted % 2 == 1 and sorted[mid + 1]
    or (sorted[mid] + sorted[mid + 1]) / 2
  return { median = median, mean = mean, sd = sd, min = min, max = max }
end

---@param cmd string[]
---@return string?
local function output_of(cmd)
  local ok, result = pcall(
    function() return vim.system(cmd, { text = true }):wait() end
  )
  if ok and result.code == 0 then return vim.trim(result.stdout) end
end

---@return string
local function machine()
  local uname = vim.uv.os_uname()
  local cpu
  if uname.sysname == 'Darwin' then
    cpu = output_of({ 'sysctl', '-n', 'machdep.cpu.brand_string' })
  elseif vim.fn.filereadable('/proc/cpuinfo') == 1 then
    for line in io.lines('/proc/cpuinfo') do
      cpu = line:match('^model name%s*:%s*(.+)$')
      if cpu then break end
    end
  end
  local os = ('%s %s'):format(uname.sysname, uname.machine)
  return cpu and ('%s (%s)'):format(cpu, os) or os
end

--- A bar `width` cells wide at 100%, drawn with eighth blocks
---@param percent number
---@param width integer
---@return string
local function bar(percent, width)
  local eighths = math.floor(percent / 100 * width * 8 + 0.5)
  local partial = { '▏', '▎', '▍', '▌', '▋', '▊', '▉' }
  local out = string.rep('█', math.floor(eighths / 8))
  if eighths % 8 > 0 then out = out .. partial[eighths % 8] end
  return out
end

--- The slowest steps of a scenario, averaged over its runs
---@param samples bench.Run[]
---@param startup number mean startup time, in ms
---@return string[]
local function top_steps(samples, startup)
  local totals = {} ---@type table<string, number>
  for _, sample in ipairs(samples) do
    for name, ms in pairs(sample.steps) do
      totals[name] = (totals[name] or 0) + ms / #samples
    end
  end
  local names = vim.tbl_keys(totals)
  table.sort(names, function(a, b) return totals[a] > totals[b] end)
  local lines =
    { ('%-28s %7s %7s  %s'):format('step', 'time', 'percent', 'plot') }
  for i = 1, math.min(10, #names) do
    local name, ms = names[i], totals[names[i]]
    local percent = ms / startup * 100
    lines[#lines + 1] = ('%-28s %7.2f %7.2f  %s'):format(
      name:sub(1, 28),
      ms,
      percent,
      bar(percent, 26)
    )
  end
  return lines
end

--- Startup medians already in the README, by command
---@param section string
---@return table<string, number>
local function recorded_medians(section)
  local medians = {}
  for cmd, median in section:gmatch('| `(.-)` | ([%d.]+) ms |') do
    medians[cmd] = tonumber(median)
  end
  return medians
end

--- Replace the benchmark section of `text`, adding the markers the first
--- time: everything under `## Benchmark` up to the next heading goes.
---@param text string
---@param section string
---@return string
local function splice(text, section)
  local s = text:find(start_marker, 1, true)
  local _, e = text:find(end_marker, 1, true)
  if s and e then return text:sub(1, s - 1) .. section .. text:sub(e + 1) end
  local _, heading = text:find('\n## Benchmark\n', 1, true)
  if not heading then error('README.md has no "## Benchmark" section') end
  local next_heading = text:find('\n## ', heading, true)
  local rest = next_heading and text:sub(next_heading) or ''
  return text:sub(1, heading) .. '\n' .. section .. '\n' .. rest
end

local ok, err = pcall(function()
  local results = {} ---@type { cmd: string, startup: table, wall: table, samples: bench.Run[] }[]
  for _, scenario in ipairs(scenarios) do
    run_once(scenario) -- warm-up: file caches, compiled Lua modules
    local samples, startups, walls = {}, {}, {}
    for i = 1, runs do
      samples[i] = run_once(scenario)
      startups[i], walls[i] = samples[i].startup, samples[i].wall
    end
    results[#results + 1] = {
      cmd = scenario.cmd,
      startup = stats(startups),
      wall = stats(walls),
      samples = samples,
    }
    io.stdout:write(
      ('bench: %-32s median %6.1f ms\n'):format(
        scenario.cmd,
        results[#results].startup.median
      )
    )
  end

  local text = table.concat(vim.fn.readfile(readme, 'b'), '\n')
  local s = text:find(start_marker, 1, true)
  local _, e = text:find(end_marker, 1, true)
  local previous = s and e and recorded_medians(text:sub(s, e)) or {}

  local moved = force or vim.tbl_isempty(previous)
  for _, r in ipairs(results) do
    local before = previous[r.cmd]
    if
      not before
      or math.abs(r.startup.median - before) / before * 100 > threshold
    then
      moved = true
    end
  end
  if not moved then
    io.stdout:write(
      ('bench: within %d%% of the README, left as is\n'):format(threshold)
    )
    return
  end

  local nvim = vim.version()
  local lines = {
    start_marker,
    '<!-- Generated by scripts/bench.lua; edit that, not this. -->',
    '',
    ('Measured with `nvim --startuptime` over %d runs on %s, Neovim %d.%d.%d, %s.'):format(
      runs,
      machine(),
      nvim.major,
      nvim.minor,
      nvim.patch,
      os.date('%Y-%m-%d')
    ),
    '',
    '| Command | Median | Mean ± σ | Min | Max | Wall clock |',
    '| ------- | -----: | -------: | --: | --: | ---------: |',
  }
  for _, r in ipairs(results) do
    lines[#lines + 1] = ('| `%s` | %.1f ms | %.1f ± %.1f ms | %.1f ms | %.1f ms | %.1f ms |'):format(
      r.cmd,
      r.startup.median,
      r.startup.mean,
      r.startup.sd,
      r.startup.min,
      r.startup.max,
      r.wall.mean
    )
  end
  vim.list_extend(lines, {
    '',
    ('Slowest steps of `%s` (self + sourced, mean):'):format(results[1].cmd),
    '',
    '```',
  })
  vim.list_extend(lines, top_steps(results[1].samples, results[1].startup.mean))
  vim.list_extend(lines, { '```', end_marker })

  -- Prose filled to 80 columns, as the rest of the README is
  lines = wrap.prose(lines)
  local updated = splice(text, table.concat(lines, '\n'))
  if updated ~= text then
    vim.fn.writefile(vim.split(updated, '\n', { plain = true }), readme, 'b')
    io.stdout:write('bench: README.md updated\n')
  end
end)

vim.fn.delete(workdir, 'rf')
if not ok then
  io.stderr:write('bench: ' .. tostring(err) .. '\n')
  os.exit(1)
end
