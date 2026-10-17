-- Time what it costs to open a file of every filetype this configuration
-- supports, and write the numbers into the Filetypes part of the Benchmark
-- section of README.md.
--
--   nvim --clean --headless -l scripts/bench-filetypes.lua
--
-- `scripts/bench.lua` times starting Neovim. That only reaches `init.lua`:
-- the `FileType` dispatcher, the language servers, the linters and
-- formatters, and every plugin that loads on a buffer event are left alone.
-- They are the part of the configuration a filetype pays for, and the part
-- that grows every time a language is added, so they are timed here.
--
-- One Neovim per filetype, so that nothing one language loads is charged to
-- the next: the order `config.languages` happens to be in would otherwise
-- decide which language looks slow. Each child reports four numbers:
--
--   open     the `:edit` itself -- the keystroke-to-buffer lag, blocking
--   ready    on to the last plugin load or language server attach it set off,
--            which is asynchronous but is still the file taking its time
--   reopen   the same file opened again, once everything is loaded: what
--            every file after the first of that type costs
--   plugins  how many lazy.nvim loaded for it
--
-- Nothing is installed: a benchmark must not download a Mason package or a
-- tree-sitter parser behind the user's back, so the installers are stubbed
-- the way `scripts/check-startup.lua` stubs them (see `scripts/lib/
-- samples.lua`). A machine missing a language's tools therefore measures the
-- configuration's own work and not the server's, which is the half this
-- repository can do anything about.
--
-- Take the milliseconds for what they are. Starting a Neovim per run makes
-- every number a whole process, and on a laptop that is noisy in a way no
-- amount of averaging removes: two sweeps of the same tree, with nothing
-- changed between them, put individual filetypes anywhere from 0.6x to 2.7x
-- of each other, and the fifteen slowest had almost nothing in common. The
-- fastest of several runs is reported because interference can only ever
-- make a run slower, which helps and does not cure it.
--
-- So:
--
-- * `plugins` is the number to watch on a single filetype. It does not move
--   between runs, and the milliseconds are mostly made of it.
-- * The summary over all the filetypes is steady where one filetype is not,
--   and is what the README is rewritten on.
-- * A change is measured by running this twice, before and after, the same
--   way round -- never against the table in the README.
-- * A filetype timed on its own with `BENCH_FT_ONLY` comes out two to four
--   times faster than the same filetype in a sweep of all of them, so those
--   two shapes are never compared with each other either.
--
-- Environment:
--   BENCH_FT_RUNS=5        measured runs per filetype, the fastest counting
--   BENCH_FT_WARMUPS=2     runs before those, thrown away
--   BENCH_FT_SETTLE=400    ms to wait for asynchronous work, per open
--   BENCH_FT_THRESHOLD=25  percent the summary must move before README changes
--   BENCH_FT_ONLY=lua,go   only these filetypes, for working on one of them
--   BENCH_FT_FORCE=1       rewrite the section whatever the numbers say

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')

-- Both roles live in one file so that the child is never out of step with the
-- driver that spawns it. `BENCH_FT_FILE` is what tells them apart: the driver
-- sets it, and the child is started with this file as its `luafile`.
local target = vim.env.BENCH_FT_FILE

--------------------------------------------------------------------------
-- Child: one file, in a Neovim that has this configuration loaded
--------------------------------------------------------------------------

if target then
  local samples = dofile(root .. '/scripts/lib/samples.lua')
  samples.skip_installs()
  samples.skip_prompts()
  -- Headless the notifier has no UI and drops what it is sent, but a plugin
  -- that formats a long message still pays for it. Nothing here reads the
  -- messages, and `check-startup.lua` is where they are looked at.
  vim.notify = function() end

  local settle = tonumber(vim.env.BENCH_FT_SETTLE) or 400
  -- The last moment the file was still busy. `LazyLoad` is lazy.nvim loading
  -- a plugin this buffer asked for, `LspAttach` a server arriving. A plugin
  -- loaded on `FileType` fires inside the `:edit`; a server, and anything
  -- loaded from a scheduled callback, lands after it has returned.
  local last = 0
  local function mark() last = vim.uv.hrtime() end
  vim.api.nvim_create_autocmd('User', { pattern = 'LazyLoad', callback = mark })
  vim.api.nvim_create_autocmd('LspAttach', { callback = mark })

  --- Open `path` and return how long it blocked for, and how long until the
  --- last of the work it set off
  ---@param path string
  ---@return number open, number ready
  local function open(path)
    last = 0
    local started = vim.uv.hrtime()
    pcall(vim.cmd.edit, vim.fn.fnameescape(path))
    local opened = vim.uv.hrtime()
    vim.wait(settle)
    local ms = function(at) return (at - started) / 1e6 end
    return ms(opened), math.max(ms(opened), ms(last))
  end

  local escaped = vim.fn.fnameescape(target)
  local open_ms, ready_ms = open(target)
  -- How many plugins this filetype brought in. Unlike the milliseconds it is
  -- the same number every run, and it is what the milliseconds are mostly
  -- made of, so it is the figure to watch when a timing is too noisy to
  -- trust.
  local loaded = 0
  for _, plugin in pairs(require('lazy.core.config').plugins) do
    if plugin._ and plugin._.loaded then loaded = loaded + 1 end
  end
  -- A second buffer on the same file, so the `:edit` is a real read and not
  -- Neovim finding the buffer it already has. Everything the filetype loads
  -- is loaded by now, which is the point of the number.
  pcall(vim.cmd.enew)
  vim.bo.buftype = 'nofile'
  pcall(vim.cmd.bwipeout, escaped)
  local reopen_ms = open(target)

  io.stdout:write(
    ('bench-ft\t%s\t%.3f\t%.3f\t%.3f\t%d\t%s\n'):format(
      vim.bo.filetype,
      open_ms,
      ready_ms,
      reopen_ms,
      loaded,
      target
    )
  )
  vim.cmd('qa!')
  return
end

--------------------------------------------------------------------------
-- Driver: a child per filetype, and the README section they add up to
--------------------------------------------------------------------------

local readme = root .. '/README.md'
local wrap = dofile(root .. '/scripts/lib/wrap.lua')
local runs = tonumber(vim.env.BENCH_FT_RUNS) or 5
local warmups = tonumber(vim.env.BENCH_FT_WARMUPS) or 2
local threshold = tonumber(vim.env.BENCH_FT_THRESHOLD) or 25
local force = vim.env.BENCH_FT_FORCE == '1'
local start_marker = '<!-- bench-filetypes:start -->'
local end_marker = '<!-- bench-filetypes:end -->'

local only ---@type table<string, true>?
if vim.env.BENCH_FT_ONLY then
  only = {}
  for _, ft in
    ipairs(vim.split(vim.env.BENCH_FT_ONLY, ',', { trimempty = true }))
  do
    only[vim.trim(ft)] = true
  end
end

-- The driver runs under `--clean`, so it knows neither this configuration's
-- modules nor the file names its `ftdetect` adds. Both are what decides which
-- files to write, so both are pulled in -- without loading the configuration
-- itself, which is the children's job.
vim.opt.rtp:prepend(root)
dofile(root .. '/ftdetect/filetype.lua')
local samples = dofile(root .. '/scripts/lib/samples.lua')

local workdir, config = dofile(root .. '/scripts/lib/workdir.lua').config(root)
local generated = samples.generate(workdir .. '/samples', { all = true })
if only then
  generated = vim.tbl_filter(function(s) return only[s.filetype] end, generated)
end

---@class bench.ft.Run
---@field open number
---@field ready number
---@field reopen number

--- Open `sample` in a Neovim of its own
---@param sample DySample
---@return bench.ft.Run
local function run_once(sample)
  local result = vim
    .system({
      'nvim',
      '--headless',
      '-i',
      'NONE',
      '-c',
      'luafile ' .. root .. '/scripts/bench-filetypes.lua',
    }, {
      cwd = workdir .. '/samples',
      env = {
        XDG_CONFIG_HOME = config,
        BENCH_FT_FILE = sample.path,
        BENCH_FT_SETTLE = vim.env.BENCH_FT_SETTLE,
      },
      text = true,
    })
    -- A filetype that hangs fails the run below, rather than holding it
    :wait(
      60000
    )
  local ft, open, ready, reopen, plugins = (result.stdout or ''):match(
    'bench%-ft\t(%S*)\t(%S+)\t(%S+)\t(%S+)\t(%S+)\t'
  )
  if not open then
    error(
      ('%s: nothing reported (exit %d)\n%s'):format(
        sample.filetype,
        result.code,
        result.stderr
      )
    )
  end
  return {
    -- What `:edit` made of the file, which is not always the filetype its
    -- name matches: `ipynb` is handed to jupytext and comes back `python`.
    -- The file is still the one that filetype asked for and the time is
    -- still its time, so it is timed and the difference is only noted.
    filetype = ft == '' and 'none' or ft,
    open = tonumber(open) --[[@as number]],
    ready = tonumber(ready) --[[@as number]],
    reopen = tonumber(reopen) --[[@as number]],
    plugins = tonumber(plugins) --[[@as number]],
  }
end

--- The CPU and operating system this ran on, for the README to name
---@return string
local function machine()
  local uname = vim.uv.os_uname()
  local cpu
  if uname.sysname == 'Darwin' then
    local ok, result = pcall(
      function()
        return vim
          .system({ 'sysctl', '-n', 'machdep.cpu.brand_string' }, { text = true })
          :wait()
      end
    )
    if ok and result.code == 0 then cpu = vim.trim(result.stdout) end
  elseif vim.fn.filereadable('/proc/cpuinfo') == 1 then
    for line in io.lines('/proc/cpuinfo') do
      cpu = line:match('^model name%s*:%s*(.+)$')
      if cpu then break end
    end
  end
  local os_name = ('%s %s'):format(uname.sysname, uname.machine)
  return cpu and ('%s (%s)'):format(cpu, os_name) or os_name
end

--- The fastest of `values`, which is what a filetype is reported as costing
---
--- The median was tried first and is not reproducible here: between two
--- sweeps of the same tree, individual filetypes moved by anything from
--- 0.14x to 2.3x, and the fifteen slowest had almost nothing in common. A
--- run can only be made slower by what else the machine is doing -- another
--- run's pages being read, the scheduler, the clock -- and never faster, so
--- the shortest of several runs is the one least interfered with, and is the
--- closest to what the configuration itself costs.
---@param values number[]
---@return number
local function fastest(values)
  local min = math.huge
  for _, v in ipairs(values) do
    min = math.min(min, v)
  end
  return min
end

--- The middle value of `values`
---@param values number[]
---@return number
local function median(values)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local mid = math.floor(#sorted / 2)
  return #sorted % 2 == 1 and sorted[mid + 1]
    or (sorted[mid] + sorted[mid + 1]) / 2
end

--- The value `percent` of the way up `values`
---@param values number[]
---@param percent number
---@return number
local function percentile(values, percent)
  local sorted = vim.deepcopy(values)
  table.sort(sorted)
  local at = math.max(1, math.ceil(#sorted * percent / 100))
  return sorted[at]
end

--- The summary `open` figures already in the README
---@param section string
---@return { median?: number, p90?: number }
local function recorded_summary(section)
  return {
    median = tonumber(section:match('| median | ([%d.]+) ms |')),
    p90 = tonumber(section:match('| 90th percentile | ([%d.]+) ms |')),
  }
end

--- Replace the filetype part of the benchmark section of `text`, adding it
--- under `## Benchmark` the first time
---@param text string
---@param section string
---@return string
local function splice(text, section)
  local s = text:find(start_marker, 1, true)
  local _, e = text:find(end_marker, 1, true)
  if s and e then return text:sub(1, s - 1) .. section .. text:sub(e + 1) end
  -- After everything `scripts/bench.lua` owns, so the two never fight over
  -- the same lines.
  local _, after = text:find('<!-- bench:end -->', 1, true)
  if not after then
    local _, heading = text:find('\n## Benchmark\n', 1, true)
    if not heading then error('README.md has no "## Benchmark" section') end
    after = heading - 1
  end
  return text:sub(1, after) .. '\n\n' .. section .. text:sub(after + 1)
end

local ok, err = pcall(function()
  ---@type { filetype: string, language: string, open: number, ready: number, reopen: number }[]
  local results = {}
  local failures = {} ---@type string[]

  for index, sample in ipairs(generated) do
    local attempt, runs_ok = pcall(function()
      -- Warm-up runs, thrown away. A filetype measured straight from cold
      -- comes out two to three times slower than the same filetype a few
      -- runs later: Lua modules are compiled and cached, and the plugins the
      -- language loads are read off disk. One run is not always enough to
      -- settle, so the budget is small but more than one.
      for _ = 1, warmups do
        run_once(sample)
      end
      local opens, readies, reopens = {}, {}, {}
      local opened, plugins = nil, 0
      for i = 1, runs do
        local run = run_once(sample)
        opens[i], readies[i], reopens[i] = run.open, run.ready, run.reopen
        opened, plugins = run.filetype, run.plugins
      end
      return {
        filetype = sample.filetype,
        language = sample.language,
        opened = opened ~= sample.filetype and opened or nil,
        plugins = plugins,
        open = fastest(opens),
        ready = fastest(readies),
        reopen = fastest(reopens),
      }
    end)
    if attempt then
      table.insert(results, runs_ok)
      io.stdout:write(
        ('bench-ft: %3d/%d %-24s open %7.1f ms  ready %7.1f ms  reopen %7.1f ms  %3d plugins\n'):format(
          index,
          #generated,
          runs_ok.filetype,
          runs_ok.open,
          runs_ok.ready,
          runs_ok.reopen,
          runs_ok.plugins
        )
      )
    else
      table.insert(failures, tostring(runs_ok))
      io.stderr:write('bench-ft: ' .. tostring(runs_ok) .. '\n')
    end
  end
  if #results == 0 then error('no filetype could be timed') end

  table.sort(results, function(a, b) return a.open > b.open end)
  local opens = vim.tbl_map(function(r) return r.open end, results)
  local readies = vim.tbl_map(function(r) return r.ready end, results)
  local reopens = vim.tbl_map(function(r) return r.reopen end, results)
  local plugins = vim.tbl_map(function(r) return r.plugins end, results)

  if only then
    io.stdout:write('bench-ft: BENCH_FT_ONLY, README left as is\n')
    return
  end

  local text = table.concat(vim.fn.readfile(readme, 'b'), '\n')
  local s = text:find(start_marker, 1, true)
  local _, e = text:find(end_marker, 1, true)
  -- Compared on the summary rather than filetype by filetype. Two sweeps of
  -- the same tree put individual filetypes anywhere from 0.6x to 2.7x of
  -- each other on this machine, whatever the runs are reduced with, so a
  -- per-filetype threshold would rewrite this section every single time. The
  -- median and the 90th percentile over a hundred and some filetypes are
  -- steady enough to say something.
  local previous = s and e and recorded_summary(text:sub(s, e)) or {}
  local summary = {
    median = median(opens),
    p90 = percentile(opens, 90),
  }
  local moved = force or vim.tbl_isempty(previous)
  for key, now in pairs(summary) do
    local before = previous[key]
    if not before or math.abs(now - before) / before * 100 > threshold then
      moved = true
    end
  end
  if not moved then
    io.stdout:write(
      ('bench-ft: within %d%% of the README, left as is\n'):format(threshold)
    )
    return
  end

  local shown = 15
  local nvim = vim.version()
  local lines = {
    start_marker,
    '<!-- Generated by scripts/bench-filetypes.lua; edit that, not this. -->',
    '',
    '### Filetypes',
    '',
    ('Opening a file of each of the %d filetypes, one Neovim per filetype, fastest of %d runs on %s, Neovim %d.%d.%d, %s.'):format(
      #results,
      runs,
      machine(),
      nvim.major,
      nvim.minor,
      nvim.patch,
      os.date('%Y-%m-%d')
    ),
    '',
    '| | `open` | `ready` | `reopen` | `plugins` |',
    '| --- | -----: | ------: | -------: | --------: |',
    ('| median | %.1f ms | %.1f ms | %.1f ms | %d |'):format(
      median(opens),
      median(readies),
      median(reopens),
      median(plugins)
    ),
    ('| 90th percentile | %.1f ms | %.1f ms | %.1f ms | %d |'):format(
      percentile(opens, 90),
      percentile(readies, 90),
      percentile(reopens, 90),
      percentile(plugins, 90)
    ),
    '',
    '`open` is the blocking `:edit`, `ready` runs on to the last plugin load or server attach it set off, and `reopen` is the same file once its filetype is loaded. `plugins` is how many lazy.nvim loaded for it, and is the same number every run where the milliseconds are not: two sweeps of the same tree put a single filetype anywhere from 0.6x to 2.7x of each other here, so read a row as an order of magnitude and the summary above as the figure that moves when something real does.',
    '',
    ('The %d slowest to open:'):format(shown),
    '',
    '| Filetype | Open | Ready | Reopen | Plugins | Language |',
    '| -------- | ---: | ----: | -----: | ------: | -------- |',
  }
  for i = 1, math.min(shown, #results) do
    local r = results[i]
    lines[#lines + 1] = ('| `%s` | %.1f ms | %.1f ms | %.1f ms | %d | %s |'):format(
      r.filetype,
      r.open,
      r.ready,
      r.reopen,
      r.plugins,
      r.language
    )
  end
  local renamed = {} ---@type string[]
  for _, r in ipairs(results) do
    if r.opened then
      renamed[#renamed + 1] = ('`%s` as `%s`'):format(r.filetype, r.opened)
    end
  end
  if #renamed > 0 then
    vim.list_extend(lines, {
      '',
      ('Opened as another filetype, and timed under the one asked for: %s.'):format(
        table.concat(renamed, ', ')
      ),
    })
  end
  if #failures > 0 then
    vim.list_extend(lines, {
      '',
      ('%d filetypes could not be timed: %s.'):format(
        #failures,
        table.concat(failures, '; ')
      ),
    })
  end
  lines[#lines + 1] = end_marker

  -- Prose filled to 80 columns, as the rest of the README is
  lines = wrap.prose(lines)
  local updated = splice(text, table.concat(lines, '\n'))
  if updated ~= text then
    vim.fn.writefile(vim.split(updated, '\n', { plain = true }), readme, 'b')
    io.stdout:write('bench-ft: README.md updated\n')
  end
end)

vim.fn.delete(workdir, 'rf')
if not ok then
  io.stderr:write('bench-ft: ' .. tostring(err) .. '\n')
  os.exit(1)
end
