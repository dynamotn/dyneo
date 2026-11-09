--- Benchmarks: run a project's own, keep each result, compare with the last
---
--- A benchmark says little alone; what matters is whether a change made it
--- slower. Each project gets the harness of its language -- `go test -bench`,
--- criterion through `cargo bench`, pytest-benchmark -- or, for any command,
--- hyperfine. A run takes long and is noisy, so it runs in a terminal split;
--- once it exits, its result is kept per project with the time and the git
--- HEAD, and compared with the previous one of the same kind in a scratch
--- buffer: one row per benchmark, regressions first.
---
--- Significance comes from the tool where it gives one: benchstat's p-value
--- over the `-count` runs of Go, criterion's confidence interval of the
--- change since its last run. hyperfine and pytest-benchmark give none; the
--- spread of each run is shown instead.
local M = {}

local notify = require('util.notify').titled('Bench')

--- The namespace of the highlights of the comparison
M.NS = vim.api.nvim_create_namespace('dy_bench')

--- Runs of each Go benchmark: benchstat needs several for a p-value
M.COUNT = 6

--- The `-bench` pattern of Go
M.PATTERN = '.'

--- Results kept per project, the most recent
M.KEEP = 20

--- Percent of change under which a benchmark reads as unchanged
M.NOISE = 2

--- p-value under which benchstat's change is significant
M.ALPHA = 0.05

--- Bytes read of a report
M.MAX_BYTES = 16 * 1024 * 1024

--- Lines of the terminal split
M.HEIGHT = 12

--- The criterion baseline each run saves and compares with
M.BASELINE = 'dyneo'

--- The project of the last run, and its harness unless it was hyperfine
---@type { tool?: DyBenchTool, root: string }?
M.last = nil

---@class DyBench
---@field name string
---@field value number Seconds per run or per iteration
---@field stddev? number Seconds
---@field change? number[] Criterion's 95% interval of the change, as fractions

---@class DyBenchResult
---@field id string Sorts by time
---@field tool string
---@field key string Results of one key compare with each other
---@field label string
---@field root string
---@field time integer
---@field head? string
---@field prev? string The id of the result of the same key before it
---@field raw? string The tool's own output, for benchstat
---@field benchmarks DyBench[]

---@class DyBenchStat
---@field sig boolean Whether the change is significant
---@field text string

--- The text of `path`, or nil and why
---@param path string
---@return string?
---@return string?
local function read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, ('No output at %s'):format(path) end
  if stat.size > M.MAX_BYTES then
    return nil, ('%s is larger than %d bytes'):format(path, M.MAX_BYTES)
  end
  local f = io.open(path, 'rb')
  if not f then return nil, ('Cannot read %s'):format(path) end
  local text = f:read('*a')
  f:close()
  return text
end

--- The JSON of `path`, or nil and why
---@param path string
---@return table?
---@return string?
local function read_json(path)
  local text, err = read(path)
  if not text then return nil, err end
  local ok, value = pcall(vim.json.decode, text)
  if not ok or type(value) ~= 'table' then
    return nil, ('%s is not JSON'):format(path)
  end
  return value
end

--- Mean and standard deviation of `xs`
---@param xs number[]
---@return number mean
---@return number? stddev Nil for a single sample
local function stats(xs)
  local sum = 0
  for _, x in ipairs(xs) do
    sum = sum + x
  end
  local mean = sum / #xs
  if #xs < 2 then return mean end
  local sq = 0
  for _, x in ipairs(xs) do
    sq = sq + (x - mean) ^ 2
  end
  return mean, math.sqrt(sq / (#xs - 1))
end

-- Parsers ---------------------------------------------------------------------

--- The short name of a Go package: its last element
---@param pkg? string
---@param name string
---@return string
local function go_name(pkg, name)
  -- shortcut: two packages of one last element mix, name them in full then
  return pkg and (vim.fs.basename(pkg) .. '.' .. name) or name
end

--- The benchmarks of `go test -bench` output, each the mean of its runs
---@param text string
---@return DyBench[]
function M.parse_go(text)
  local samples, order, pkg = {}, {}, nil
  for line in vim.gsplit(text, '\n', { plain = true }) do
    pkg = line:match('^pkg: (%S+)') or pkg
    local name, ns = line:match('^Benchmark(%S+)%s+%d+%s+([%d.e+-]+) ns/op')
    if name and tonumber(ns) then
      name = go_name(pkg, name)
      if not samples[name] then
        samples[name] = {}
        table.insert(order, name)
      end
      table.insert(samples[name], tonumber(ns) / 1e9)
    end
  end
  return vim.tbl_map(function(name)
    local mean, stddev = stats(samples[name])
    return { name = name, value = mean, stddev = stddev }
  end, order)
end

--- The p-value of each benchmark of `benchstat -format csv`, from its
--- `sec/op` tables
---@param text string
---@return table<string, DyBenchStat>
function M.parse_benchstat(text)
  local out, pkg, in_time = {}, nil, false
  for line in vim.gsplit(text, '\n', { plain = true }) do
    line = line:gsub('\r$', '')
    pkg = line:match('^pkg: (%S+)') or pkg
    if line == '' then
      in_time = false
    elseif line:match('^,') then
      in_time = line:find('sec/op', 1, true) ~= nil
    elseif in_time then
      local name = line:match('^([^,]+),')
      local p = tonumber(line:match('p=([%d.]+)'))
      if name and p and name ~= 'geomean' then
        out[go_name(pkg, name)] =
          { sig = p < M.ALPHA, text = ('p=%s'):format(p) }
      end
    end
  end
  return out
end

--- The benchmarks of a hyperfine `--export-json`, of its schema 2 (2.0) or
--- of 1.x
---@param report table
---@return DyBench[]
function M.parse_hyperfine(report)
  local benches = {}
  for _, result in ipairs(report.results or {}) do
    local wall = type(result.summary) == 'table'
        and result.summary.time_wall_clock
      or result
    if type(wall.mean) == 'number' then
      table.insert(benches, {
        name = result.name or result.command or '?',
        value = wall.mean,
        stddev = wall.stddev,
      })
    end
  end
  return benches
end

--- The benchmarks of a pytest-benchmark `--benchmark-json`
---@param report table
---@return DyBench[]
function M.parse_pytest(report)
  local benches = {}
  for _, bench in ipairs(report.benchmarks or {}) do
    local s = bench.stats or {}
    if type(s.mean) == 'number' then
      table.insert(benches, {
        name = bench.fullname or bench.name or '?',
        value = s.mean,
        stddev = s.stddev,
      })
    end
  end
  return benches
end

--- One criterion benchmark, from its `new/benchmark.json`, `estimates.json`
--- (nanoseconds) and, when it was compared, `change/estimates.json`
---@param bench table
---@param estimates table
---@param change? table
---@return DyBench?
function M.criterion(bench, estimates, change)
  local mean = estimates.mean or {}
  if type(mean.point_estimate) ~= 'number' then return nil end
  local sd = estimates.std_dev and estimates.std_dev.point_estimate
  local ci = change and change.mean and change.mean.confidence_interval
  return {
    name = bench.full_id or bench.title or '?',
    value = mean.point_estimate / 1e9,
    stddev = type(sd) == 'number' and sd / 1e9 or nil,
    change = ci and { ci.lower_bound, ci.upper_bound } or nil,
  }
end

--- The criterion benchmarks under `root/target/criterion` measured since
--- `since`, so those of an earlier run are left out
---@param root string
---@param since integer Seconds
---@return DyBench[]?
---@return string?
function M.read_criterion(root, since)
  local dir = vim.fs.joinpath(root, 'target', 'criterion')
  local found = vim.fn.isdirectory(dir) == 1
      and vim.fs.find(
        function(name, path)
          return name == 'benchmark.json' and vim.fs.basename(path) == 'new'
        end,
        { path = dir, type = 'file', limit = math.huge }
      )
    or {}
  table.sort(found)
  local benches = {}
  for _, path in ipairs(found) do
    local new = vim.fs.dirname(path)
    local est_path = vim.fs.joinpath(new, 'estimates.json')
    local stat = vim.uv.fs_stat(est_path)
    if stat and stat.mtime.sec >= since then
      local bench, err = read_json(path)
      if not bench then return nil, err end
      local estimates, err2 = read_json(est_path)
      if not estimates then return nil, err2 end
      local change_path =
        vim.fs.joinpath(vim.fs.dirname(new), 'change', 'estimates.json')
      local cstat = vim.uv.fs_stat(change_path)
      local change = cstat
        and cstat.mtime.sec >= since
        and read_json(change_path)
      local b = M.criterion(bench, estimates, change or nil)
      if b then table.insert(benches, b) end
    end
  end
  if #found == 0 then
    return nil,
      ('No criterion results in %s'):format(vim.fn.fnamemodify(dir, ':~'))
  end
  return benches
end

-- The tools -------------------------------------------------------------------

--- The first of `paths` (relative to `root`) that is executable, else `bin`
---@param root string
---@param paths string[]
---@param bin string
---@return string
local function local_bin(root, paths, bin)
  for _, path in ipairs(paths) do
    local full = vim.fs.joinpath(root, path)
    if vim.fn.executable(full) == 1 then return full end
  end
  return bin
end

---@class DyBenchTool
---@field name string
---@field key string
---@field filetypes string[]
---@field markers string[]
---@field mason? string Its Mason package; none for a toolchain or the project's own
---@field missing? string What to do when it is not installed, without Mason
---@field hint? string Said when a run fails
---@field bin fun(root: string): string
---@field cmd fun(root: string, raw: string, arg?: string): string[]
---@field read fun(root: string, raw: string, since: integer): DyBench[]?, string?

--- The harness of each language, in the order a project of several tries
---@type DyBenchTool[]
M.TOOLS = {
  {
    name = 'go test',
    key = 'go',
    filetypes = { 'go' },
    markers = { 'go.mod' },
    missing = 'go is not installed',
    bin = function() return 'go' end,
    -- Shown as it runs and kept for benchstat; `pipefail` keeps its exit
    cmd = function(_, raw)
      return {
        'bash',
        '-o',
        'pipefail',
        '-c',
        '"$@" 2>&1 | tee "$0"',
        raw,
        'go',
        'test',
        '-run',
        '^$',
        '-bench',
        M.PATTERN,
        '-benchmem',
        '-count=' .. M.COUNT,
        './...',
      }
    end,
    read = function(_, raw)
      local text, err = read(raw)
      if not text then return nil, err end
      return M.parse_go(text)
    end,
  },
  {
    name = 'criterion',
    key = 'criterion',
    filetypes = { 'rust' },
    markers = { 'Cargo.toml' },
    missing = 'cargo is not installed',
    hint = 'the benches must use criterion',
    bin = function() return 'cargo' end,
    cmd = function()
      return { 'cargo', 'bench', '--', '--save-baseline', M.BASELINE }
    end,
    read = function(root, _, since) return M.read_criterion(root, since) end,
  },
  {
    name = 'pytest-benchmark',
    key = 'pytest',
    filetypes = { 'python' },
    markers = { 'pyproject.toml', 'setup.cfg', 'setup.py', 'pytest.ini' },
    missing = 'pytest is not installed in the project',
    hint = 'is pytest-benchmark installed in the project?',
    -- The project's own, which imports its dependencies
    bin = function(root)
      return local_bin(
        root,
        { '.venv/bin/pytest', 'venv/bin/pytest' },
        'pytest'
      )
    end,
    cmd = function(root, raw)
      return {
        local_bin(root, { '.venv/bin/pytest', 'venv/bin/pytest' }, 'pytest'),
        '--benchmark-only',
        '--benchmark-json=' .. raw,
      }
    end,
    read = function(_, raw)
      local report, err = read_json(raw)
      if not report then return nil, err end
      return M.parse_pytest(report)
    end,
  },
}

--- hyperfine, for any command
---@type DyBenchTool
M.HYPERFINE = {
  name = 'hyperfine',
  key = 'hyperfine',
  filetypes = {},
  markers = {},
  mason = 'hyperfine',
  bin = function() return 'hyperfine' end,
  cmd = function(_, raw, command)
    return { 'hyperfine', '--export-json', raw, '--', command }
  end,
  read = function(_, raw)
    local report, err = read_json(raw)
    if not report then return nil, err end
    return M.parse_hyperfine(report)
  end,
}

--- The harness for buffer `buf` and the root of its project: the one of its
--- filetype; from a terminal or another buffer of no file, the project of
--- the last run; else the first whose files are at the root of the project
---@param buf integer
---@return DyBenchTool?
---@return string? root
function M.detect(buf)
  local ft = vim.bo[buf].filetype
  for _, tool in ipairs(M.TOOLS) do
    if vim.tbl_contains(tool.filetypes, ft) then
      local root = vim.fs.root(buf, tool.markers)
      if root then return tool, vim.uv.fs_realpath(root) or root end
    end
  end
  if vim.bo[buf].buftype ~= '' and M.last then
    return M.last.tool, M.last.root
  end
  local root = M.root()
  for _, tool in ipairs(M.TOOLS) do
    for _, marker in ipairs(tool.markers) do
      if vim.uv.fs_stat(vim.fs.joinpath(root, marker)) then
        return tool, root
      end
    end
  end
end

--- The root of the project of the current buffer, its real path
---@return string
function M.root()
  local root = require('util.root')()
  return vim.uv.fs_realpath(root) or root
end

-- Storage ---------------------------------------------------------------------

--- Where the results of the project at `root` are kept
---@param root string
---@return string
function M.dir(root)
  return vim.fs.joinpath(
    vim.fn.stdpath('state'),
    'dyneo',
    'bench',
    vim.fn.sha256(root):sub(1, 16)
  )
end

--- The result files of `root`, oldest first
---@param root string
---@return string[]
local function files(root)
  local dir = M.dir(root)
  local out = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:match('%.json$') then
      table.insert(out, vim.fs.joinpath(dir, name))
    end
  end
  table.sort(out)
  return out
end

--- The saved results of `root`, oldest first; an unreadable one is left out
---@param root string
---@return DyBenchResult[]
function M.results(root)
  local out = {}
  for _, path in ipairs(files(root)) do
    local result = read_json(path)
    if result and type(result.benchmarks) == 'table' then
      table.insert(out, result)
    end
  end
  return out
end

--- Remove all but the `M.KEEP` most recent results of `root`
---@param root string
function M.prune(root)
  local all = files(root)
  for i = 1, #all - M.KEEP do
    os.remove(all[i])
    os.remove((all[i]:gsub('%.json$', '.raw')))
  end
end

--- Keep `result` for `root`, then prune
---@param root string
---@param result DyBenchResult
function M.save(root, result)
  vim.fn.mkdir(M.dir(root), 'p')
  local path = vim.fs.joinpath(M.dir(root), result.id .. '.json')
  vim.fn.writefile({ vim.json.encode(result) }, path)
  M.prune(root)
end

--- The latest result of `key` in `results` before index `before`
---@param results DyBenchResult[]
---@param key string
---@param before? integer
---@return DyBenchResult?
local function latest(results, key, before)
  for i = (before or #results + 1) - 1, 1, -1 do
    if results[i].key == key then return results[i], i end
  end
end

-- Comparing -------------------------------------------------------------------

---@alias DyBenchKind 'regression'|'improvement'|'same'|'added'|'removed'

---@class DyBenchRow
---@field name string
---@field old? DyBench
---@field new? DyBench
---@field delta? number Percent
---@field stat? DyBenchStat
---@field kind DyBenchKind

local ORDER =
  { regression = 1, improvement = 2, same = 3, added = 4, removed = 5 }

--- The rows of `new` against `old`, regressions first, the worst first
---@param old? DyBenchResult
---@param new DyBenchResult
---@param stats_by_name? table<string, DyBenchStat>
---@return DyBenchRow[]
function M.compare(old, new, stats_by_name)
  stats_by_name = stats_by_name or {}
  local before = {}
  for _, b in ipairs(old and old.benchmarks or {}) do
    before[b.name] = b
  end
  local rows, seen = {}, {}
  for _, b in ipairs(new.benchmarks) do
    seen[b.name] = true
    local a = before[b.name]
    local row = { name = b.name, old = a, new = b, kind = 'added' }
    if a then
      row.stat = stats_by_name[b.name]
      -- No test from the tool: a change inside the spread of a run is noise
      if
        not row.stat
        and a.stddev
        and b.stddev
        and math.abs(b.value - a.value) < math.max(a.stddev, b.stddev)
      then
        row.stat = { sig = false, text = 'within the spread' }
      end
      row.kind = 'same'
      if a.value > 0 then
        row.delta = (b.value - a.value) / a.value * 100
        local noisy = row.stat and not row.stat.sig
        if not noisy and row.delta >= M.NOISE then
          row.kind = 'regression'
        elseif not noisy and row.delta <= -M.NOISE then
          row.kind = 'improvement'
        end
      end
    end
    table.insert(rows, row)
  end
  for _, a in ipairs(old and old.benchmarks or {}) do
    if not seen[a.name] then
      table.insert(rows, { name = a.name, old = a, kind = 'removed' })
    end
  end
  table.sort(rows, function(x, y)
    if x.kind ~= y.kind then return ORDER[x.kind] < ORDER[y.kind] end
    if x.delta and y.delta and x.delta ~= y.delta then
      if x.kind == 'improvement' then return x.delta < y.delta end
      return x.delta > y.delta
    end
    return x.name < y.name
  end)
  return rows
end

--- `seconds` in the unit that fits it
---@param seconds number
---@return string
function M.duration(seconds)
  local abs = math.abs(seconds)
  if abs < 1e-6 then return ('%.2f ns'):format(seconds * 1e9) end
  if abs < 1e-3 then return ('%.2f µs'):format(seconds * 1e6) end
  if abs < 1 then return ('%.2f ms'):format(seconds * 1e3) end
  return ('%.2f s'):format(seconds)
end

--- A benchmark's value with its spread
---@param b? DyBench
---@return string
local function cell(b)
  if not b then return '-' end
  local text = M.duration(b.value)
  if b.stddev and b.value > 0 then
    text = ('%s ±%.0f%%'):format(text, b.stddev / b.value * 100)
  end
  return text
end

--- How `result` reads in a heading
---@param result DyBenchResult
---@return string
local function heading(result)
  return ('%s%s'):format(
    os.date('%Y-%m-%d %H:%M', result.time),
    result.head and (' at ' .. result.head:sub(1, 10)) or ''
  )
end

--- The lines of the comparison, and the highlight of each row by line
---@param old? DyBenchResult
---@param new DyBenchResult
---@param rows DyBenchRow[]
---@param note? string Said under the heading
---@return string[]
---@return table<integer, string> Highlight groups by 0-based line
function M.lines(old, new, rows, note)
  local lines = {
    ('# %s: %s'):format(new.tool, new.label),
    ('new: %s'):format(heading(new)),
    old and ('old: %s'):format(heading(old))
      or 'old: none, no earlier result of this kind to compare with',
  }
  if note then table.insert(lines, note) end
  if old then
    local shared = vim.iter(rows):any(function(r) return r.old and r.new end)
    if not shared then
      table.insert(lines, 'The two results share no benchmark.')
    end
  end
  table.insert(lines, '')
  local tbl = { { 'Benchmark', 'Old', 'New', 'Delta', 'Significance' } }
  for _, row in ipairs(rows) do
    table.insert(tbl, {
      row.name,
      cell(row.old),
      cell(row.new),
      row.delta and ('%+.1f%%'):format(row.delta) or row.kind,
      row.stat and (row.stat.text .. (row.stat.sig and '' or ' (noise)')) or '',
    })
  end
  local widths = {}
  for _, cols in ipairs(tbl) do
    for i, text in ipairs(cols) do
      widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(text))
    end
  end
  local hls = {}
  local groups =
    { regression = 'DiagnosticError', improvement = 'DiagnosticOk' }
  for i, cols in ipairs(tbl) do
    local padded = {}
    for c, text in ipairs(cols) do
      padded[c] = text .. (' '):rep(widths[c] - vim.fn.strdisplaywidth(text))
    end
    table.insert(lines, vim.trim(table.concat(padded, '  ')))
    local row = rows[i - 1]
    if row and groups[row.kind] then hls[#lines - 1] = groups[row.kind] end
  end
  return lines, hls
end

--- The significance of the benchmarks of `new` against `old`, as the tool
--- gives it: benchstat's p-value for Go, criterion's interval of the change
--- when `old` is the result it compared with
---@param old DyBenchResult
---@param new DyBenchResult
---@param on_done fun(stats: table<string, DyBenchStat>, note?: string)
function M.significance(old, new, on_done)
  if new.tool == 'criterion' then
    local out = {}
    if new.prev == old.id then
      for _, b in ipairs(new.benchmarks) do
        if b.change then
          local lo, hi = b.change[1], b.change[2]
          out[b.name] = {
            sig = lo > 0 or hi < 0,
            text = ('[%+.1f%%, %+.1f%%]'):format(lo * 100, hi * 100),
          }
        end
      end
    end
    return on_done(out)
  end
  if new.tool ~= 'go test' or not (old.raw and new.raw) then
    return on_done({})
  end
  if vim.fn.executable('benchstat') == 0 then
    require('util.lazy_install').install_once('benchstat')
    return on_done(
      {},
      'benchstat is not installed: no significance; Mason installs it'
    )
  end
  local dir = M.dir(new.root)
  require('util.system').run({
    'benchstat',
    '-format',
    'csv',
    vim.fs.joinpath(dir, old.raw),
    vim.fs.joinpath(dir, new.raw),
  }, { timeout = 30000 }, function(r)
    if r.code ~= 0 then
      return on_done(
        {},
        ('benchstat failed, no significance: %s'):format(
          vim.trim(r.stderr):sub(1, 200)
        )
      )
    end
    on_done(M.parse_benchstat(r.stdout))
  end)
end

--- Compare `new` with `old` in a scratch buffer, regressions highlighted
---@param old? DyBenchResult
---@param new DyBenchResult
function M.show(old, new)
  local function render(stats_by_name, note)
    local rows = M.compare(old, new, stats_by_name)
    local lines, hls = M.lines(old, new, rows, note)
    local buf = require('util.scratch').open(lines, {
      name = 'DyBench ' .. new.id,
      filetype = 'markdown',
    })
    for line, group in pairs(hls) do
      vim.api.nvim_buf_set_extmark(
        buf,
        M.NS,
        line,
        0,
        { line_hl_group = group }
      )
    end
    local regressions =
      #vim.tbl_filter(function(r) return r.kind == 'regression' end, rows)
    if not old then
      notify(
        ('%s: %d benchmarks kept; nothing earlier to compare with'):format(
          new.tool,
          #new.benchmarks
        )
      )
    elseif regressions > 0 then
      notify(
        ('%s: %d slower than before'):format(new.tool, regressions),
        vim.log.levels.WARN
      )
    end
  end
  if not old then return render({}) end
  M.significance(old, new, render)
end

-- Commands --------------------------------------------------------------------

--- Run `tool` in a terminal on the project at `root`, keep its result and
--- compare it with the previous one of its key
---@param tool DyBenchTool
---@param root string
---@param arg? string The command, for hyperfine
local function start(tool, root, arg)
  if vim.fn.executable(tool.bin(root)) == 0 then
    if tool.mason then
      require('util.lazy_install').install_once(tool.mason)
      return notify(
        ('%s is not installed: Mason installs it, run again once it is done'):format(
          tool.name
        ),
        vim.log.levels.ERROR
      )
    end
    return notify(tool.missing, vim.log.levels.ERROR)
  end
  local question = ('Run %s in %s?\nIt runs the code of the project as you.'):format(
    arg and ('hyperfine on `%s`'):format(arg) or tool.name,
    vim.fn.fnamemodify(root, ':~')
  )
  if not require('util.trust').ask('bench', root, question) then
    return notify(
      ('%s not run: the project is not trusted'):format(tool.name),
      vim.log.levels.WARN
    )
  end

  M.last = { tool = arg == nil and tool or nil, root = root }
  require('util.system').run(
    { 'git', 'rev-parse', 'HEAD' },
    { cwd = root, timeout = 5000 },
    function(git)
      local head = git.code == 0 and vim.trim(git.stdout) or nil
      local id = ('%s-%03d-%s'):format(
        os.date('%Y%m%d-%H%M%S'),
        math.floor(vim.uv.hrtime() / 1e6) % 1000,
        tool.key
      )
      local dir = M.dir(root)
      vim.fn.mkdir(dir, 'p')
      local raw = vim.fs.joinpath(dir, id .. '.raw')
      local since = os.time()
      vim.cmd('botright ' .. M.HEIGHT .. 'split')
      vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
      vim.fn.jobstart(tool.cmd(root, raw, arg), {
        term = true,
        cwd = root,
        on_exit = function(_, code)
          vim.schedule(function()
            local function fail(msg)
              os.remove(raw)
              notify(msg, vim.log.levels.ERROR)
            end
            if code ~= 0 then
              return fail(
                ('%s exited %d: see its terminal; nothing kept%s'):format(
                  tool.name,
                  code,
                  tool.hint and (' (' .. tool.hint .. ')') or ''
                )
              )
            end
            local benches, err = tool.read(root, raw, since)
            if not benches then
              return fail(('%s: unreadable output: %s'):format(tool.name, err))
            end
            if #benches == 0 then
              return fail(
                ('%s ran no benchmark: nothing kept'):format(tool.name)
              )
            end
            local key = arg and (tool.key .. ':' .. arg) or tool.key
            local prev = latest(M.results(root), key)
            ---@type DyBenchResult
            local result = {
              id = id,
              tool = tool.name,
              key = key,
              label = arg or vim.fn.fnamemodify(root, ':~'),
              root = root,
              time = since,
              head = head,
              prev = prev and prev.id,
              raw = vim.uv.fs_stat(raw) and vim.fs.basename(raw) or nil,
              benchmarks = benches,
            }
            M.save(root, result)
            M.show(prev, result)
          end)
        end,
      })
      vim.cmd.startinsert()
    end
  )
end

--- `:DyBench`: run the benchmarks of the project of the buffer
function M.run()
  local tool, root = M.detect(0)
  if not tool or not root then
    return notify(
      'No Go, Rust or Python project here: `:DyBench cmd {command}` times any command',
      vim.log.levels.WARN
    )
  end
  start(tool, root)
end

--- `:DyBench cmd {command}`: time `command` with hyperfine
---@param command string
function M.run_cmd(command)
  if vim.trim(command) == '' then
    return notify('Give the command to time', vim.log.levels.ERROR)
  end
  local _, root = M.detect(0)
  start(M.HYPERFINE, root or M.root(), command)
end

--- The project root `compare` and `list` read
---@return string
local function project()
  local _, root = M.detect(0)
  return root or M.root()
end

--- `:DyBench compare [{ref}]`: the latest result against the one before it
--- of its kind, or against the latest recorded at git `ref`
---@param ref? string
function M.compare_cmd(ref)
  local root = project()
  local results = M.results(root)
  local new = results[#results]
  if not new then
    return notify(
      ('No benchmark result kept for %s'):format(vim.fn.fnamemodify(root, ':~')),
      vim.log.levels.WARN
    )
  end
  if not ref or ref == '' then
    local old = latest(results, new.key, #results)
    if not old then
      return notify(
        ('Only one %s result: nothing to compare with'):format(new.tool),
        vim.log.levels.WARN
      )
    end
    return M.show(old, new)
  end
  require('util.system').run(
    { 'git', 'rev-parse', '--verify', '--end-of-options', ref .. '^{commit}' },
    { cwd = root, timeout = 5000 },
    function(git)
      if git.code ~= 0 then
        return notify(
          ('Not a git revision: %s'):format(ref),
          vim.log.levels.ERROR
        )
      end
      local sha = vim.trim(git.stdout)
      for i = #results - 1, 1, -1 do
        local r = results[i]
        if r.key == new.key and r.head == sha then return M.show(r, new) end
      end
      notify(
        ('No %s result recorded at %s (%s)'):format(
          new.tool,
          ref,
          sha:sub(1, 10)
        ),
        vim.log.levels.ERROR
      )
    end
  )
end

--- `:DyBench list`: pick a kept result and compare the latest of its kind
--- with it, or it with the one before when it is the latest
function M.list()
  local root = project()
  local results = M.results(root)
  if #results == 0 then
    return notify(
      ('No benchmark result kept for %s'):format(vim.fn.fnamemodify(root, ':~')),
      vim.log.levels.WARN
    )
  end
  local items = vim.fn.reverse(vim.deepcopy(results))
  vim.ui.select(items, {
    prompt = 'Benchmark result',
    format_item = function(r)
      return ('%s  %s  %s  (%d)'):format(
        heading(r),
        r.tool,
        r.label,
        #r.benchmarks
      )
    end,
  }, function(picked)
    if not picked then return end
    local newest = latest(results, picked.key)
    if newest and newest.id ~= picked.id then return M.show(picked, newest) end
    local index
    for i, r in ipairs(results) do
      if r.id == picked.id then index = i end
    end
    M.show(latest(results, picked.key, index), picked)
  end)
end

return M
