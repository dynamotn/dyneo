--- Flaky tests: one test run many times, to tell flaky from broken
---
--- The test under the cursor (neotest's nearest position when an adapter
--- has parsed the buffer, else the enclosing test function found by its
--- pattern), or every test of the file, runs `M.RUNS` times by the tool's own
--- command -- not through neotest, so each run is independent and counted.
--- Go runs once as `go test -json -count=N` and each iteration is read from
--- its events; pytest, jest, Vitest and `cargo test` run once per run, one
--- after the other, each with its own deadline. The report says how many
--- passed, the distinct failure messages and how often each came, the
--- durations, and a verdict: stable pass, flaky, or always fails.
local M = {}

local system = require('util.system')

--- Runs when no count is given
M.RUNS = 10

--- Milliseconds one run may take
M.TIMEOUT = 5 * 60 * 1000

--- Output kept of one run
M.MAX_BYTES = 1024 * 1024

--- Lines of a failing output kept in the report, per distinct message
M.OUTPUT_LINES = 40

--- Characters of a failure message kept
M.MESSAGE_WIDTH = 200

--- The id progress notifications replace each other under
M.NOTIFY_ID = 'dy_flaky'

---@alias DyFlakyLanguage 'go'|'python'|'js'|'rust'

---@class DyFlakyName
---@field kind 'test'|'namespace'
---@field name string

---@class DyFlakyTarget
---@field language DyFlakyLanguage
---@field root string The project, where the command runs
---@field file string The test file, relative to `root`
---@field chain? DyFlakyName[] The test, outer to inner; nil for the file
---@field names? string[] Go: the top-level tests run
---@field label string What the report calls it

---@class DyFlakyRun
---@field status 'pass'|'fail'|'timeout'
---@field ms number
---@field message? string The first line of the failure
---@field output? string

---@class DyFlakyCommand
---@field cmd string[]
---@field json? boolean Go: one process for every run, read by `M.go_runs`
---@field timeout integer

---@class DyFlakySummary
---@field runs integer
---@field passes integer
---@field rate number Failures per run, 0 to 1
---@field failures { message: string, count: integer, output?: string }[]
---@field min? number
---@field median? number
---@field max? number
---@field verdict string

--- The language of each filetype it runs
---@type table<string, DyFlakyLanguage>
M.FILETYPES = {
  go = 'go',
  python = 'python',
  javascript = 'js',
  javascriptreact = 'js',
  typescript = 'js',
  typescriptreact = 'js',
  rust = 'rust',
}

--- The files marking the root of a project of each language
---@type table<DyFlakyLanguage, string[]>
M.MARKERS = {
  go = { 'go.mod' },
  python = {
    'pyproject.toml',
    'setup.cfg',
    'setup.py',
    'pytest.ini',
    'tox.ini',
  },
  js = { 'package.json' },
  rust = { 'Cargo.toml' },
}

--- `vim.notify` titled `DyNeo Flaky`, returning what it returns
local function notify(msg, level, opts)
  return vim.notify(
    msg,
    level or vim.log.levels.INFO,
    vim.tbl_extend(
      'force',
      opts or {},
      { title = require('util.notify').title('Flaky') }
    )
  )
end

--- `name` without the quotes an adapter may leave around it
---@param name string
---@return string
local function unquote(name) return (name:gsub('^(["\'`])(.*)%1$', '%2')) end

-- Finding the test ------------------------------------------------------------

--- The test at 0-based `row` of `bufnr` as neotest knows it, when an adapter
--- has parsed the buffer
---@param bufnr integer
---@param row integer
---@return DyFlakyName[]?
function M.from_neotest(bufnr, row)
  -- Only a neotest already running has positions; loading it here would not
  if not package.loaded['neotest'] then return nil end
  local ok, chain = pcall(function()
    local neotest = require('neotest')
    local nearest = require('neotest.lib').positions.nearest
    for _, id in ipairs(neotest.state.adapter_ids()) do
      local tree = neotest.state.positions(id, { buffer = bufnr })
      if tree then
        local chain, node, test = {}, nearest(tree, row), false
        while node do
          local data = node:data()
          if data.type == 'test' or data.type == 'namespace' then
            test = test or data.type == 'test'
            table.insert(
              chain,
              1,
              { kind = data.type, name = unquote(data.name) }
            )
          end
          node = node:parent()
        end
        if test then return chain end
      end
    end
  end)
  return ok and chain or nil
end

--- The indent of `line`, in characters
---@param line string
---@return integer
local function indent(line) return #line:match('^%s*') end

--- The definitions of each language: the line of a test, and of the
--- namespace around one
local DEFINITIONS = {
  go = { test = { '^func%s+(Test[%w_]*)%s*%(' } },
  python = {
    test = { '^%s*def%s+(test[%w_]*)', '^%s*async%s+def%s+(test[%w_]*)' },
    namespace = '^%s*class%s+([%w_]+)',
  },
  -- shortcut: `it.each` and template-literal names are not found; neotest's
  -- position is taken first when it has one
  js = {
    test = { '^%s*it%s*%(%s*([\'"`])(.-)%1', '^%s*test%s*%(%s*([\'"`])(.-)%1' },
  },
  rust = {
    test = { '^%s*[%w%s()]-fn%s+([%w_]+)' },
    namespace = '^%s*[%w%s()]-mod%s+([%w_]+)%s*{',
  },
}

--- The enclosing test of 1-based `row` among `lines`, by the patterns of
--- `language`: the nearest test definition at or above it, and the
--- namespaces around it
---@param lines string[]
---@param row integer
---@param language DyFlakyLanguage
---@return DyFlakyName[]?
function M.scan(lines, row, language)
  local defs = DEFINITIONS[language]
  for i = math.min(row, #lines), 1, -1 do
    local line = lines[i]
    local name
    for _, pattern in ipairs(defs.test) do
      local a, b = line:match(pattern)
      name = b or a
      if name then break end
    end
    -- A Rust function is a test only under a `#[test]`-like attribute
    if name and language == 'rust' then
      local attr = false
      for j = i - 1, math.max(1, i - 3), -1 do
        if lines[j]:match('^%s*#%[[%w_:]*test') then attr = true end
      end
      if not attr then name = nil end
    end
    if name then
      local chain = { { kind = 'test', name = name } }
      local depth = indent(line)
      if defs.namespace then
        for j = i - 1, 1, -1 do
          if depth == 0 then break end
          local space = lines[j]:match(defs.namespace)
          if space and indent(lines[j]) < depth then
            table.insert(chain, 1, { kind = 'namespace', name = space })
            depth = indent(lines[j])
          end
        end
      end
      return chain
    end
  end
  return nil
end

--- The top-level Go tests among `lines`
---@param lines string[]
---@return string[]
function M.go_tests(lines)
  local names = {}
  for _, line in ipairs(lines) do
    local name = line:match(DEFINITIONS.go.test[1])
    if name then table.insert(names, name) end
  end
  return names
end

--- What `:DyFlaky` runs in `bufnr`: the test under the cursor, or the file
---@param bufnr integer
---@param whole_file? boolean
---@return DyFlakyTarget?
---@return string? err
function M.target(bufnr, whole_file)
  local language = M.FILETYPES[vim.bo[bufnr].filetype]
  if not language then
    return nil,
      ('No flaky-test run for filetype %q: Go, Python, JavaScript, TypeScript and Rust have one'):format(
        vim.bo[bufnr].filetype
      )
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  file = vim.uv.fs_realpath(file) or file
  local root = vim.fs.root(file, M.MARKERS[language])
  if not root then
    return nil,
      ('No %s above %s'):format(
        table.concat(M.MARKERS[language], ' or '),
        vim.fn.fnamemodify(file, ':~')
      )
  end
  root = vim.uv.fs_realpath(root) or root
  local rel = file:sub(#root + 2)
  local target = { language = language, root = root, file = rel, label = rel }
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if whole_file then
    if language == 'go' then
      target.names = M.go_tests(lines)
      if #target.names == 0 then
        return nil, ('No Test function in %s'):format(rel)
      end
    end
    return target
  end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local chain = M.from_neotest(bufnr, row - 1) or M.scan(lines, row, language)
  if not chain then return nil, ('No test at the cursor in %s'):format(rel) end
  target.chain = chain
  local names = vim.tbl_map(function(n) return n.name end, chain)
  target.label = ('%s %s'):format(rel, table.concat(names, '::'))
  if language == 'go' then
    -- The top-level test: `-run` is matched per level, and subtests are
    -- counted with it
    target.names = { names[1] }
    for _, n in ipairs(chain) do
      if n.kind == 'test' then
        target.names = { n.name }
        break
      end
    end
  end
  return target
end

-- The commands ----------------------------------------------------------------

--- The first of `paths` (relative to `root`) that is executable
---@param root string
---@param paths string[]
---@return string?
local function local_bin(root, paths)
  for _, path in ipairs(paths) do
    local full = vim.fs.joinpath(root, path)
    if vim.fn.executable(full) == 1 then return full end
  end
end

--- `text` with every character special to a JavaScript regex escaped
---@param text string
---@return string
function M.js_escape(text)
  return (text:gsub('[%^%$%(%)%.%[%]%*%+%-%?{}|\\/]', '\\%0'))
end

--- Whether the Python project at `root` uses pytest-randomly itself
---@param root string
---@return boolean
local function uses_randomly(root)
  local files = { 'pyproject.toml', 'setup.cfg', 'tox.ini', 'pytest.ini' }
  vim.list_extend(
    files,
    vim.fn.globpath(root, 'requirements*.txt', false, true)
  )
  for _, file in ipairs(files) do
    local path = vim.startswith(file, '/') and file
      or vim.fs.joinpath(root, file)
    local stat = vim.uv.fs_stat(path)
    -- Only a configuration file's size is read
    if stat and stat.size < 1024 * 1024 then
      for _, line in ipairs(vim.fn.readfile(path)) do
        if line:find('randomly', 1, true) then return true end
      end
    end
  end
  return false
end

--- The Rust module path of `rel` within its crate, and its test target
---@param rel string
---@return string[] modules
---@return string? test The `--test` target of a file under `tests/`
local function rust_module(rel)
  local test = rel:match('^tests/([^/]+)%.rs$')
  if test then return {}, test end
  local inner = rel:match('^src/(.+)%.rs$')
  if not inner or inner == 'lib' or inner == 'main' then return {}, nil end
  local parts = vim.split(inner, '/', { plain = true })
  if parts[#parts] == 'mod' then table.remove(parts) end
  return parts, nil
end

--- The command running `target` once, or (Go) `runs` times; nil and why
--- when the tool is not there
---@param target DyFlakyTarget
---@param runs integer
---@return DyFlakyCommand?
---@return string? err
function M.command(target, runs)
  local root, rel, chain = target.root, target.file, target.chain
  local names = chain and vim.tbl_map(function(n) return n.name end, chain)
  if target.language == 'go' then
    local dir = vim.fs.dirname(rel)
    -- go's own deadline is for the whole binary: every run of it
    local seconds = math.ceil(M.TIMEOUT * runs / 1000)
    return {
      cmd = {
        'go',
        'test',
        '-json',
        '-count=' .. runs,
        '-timeout=' .. seconds .. 's',
        '-run',
        '^(' .. table.concat(target.names, '|') .. ')$',
        dir == '.' and '.' or './' .. dir,
      },
      json = true,
      timeout = M.TIMEOUT * runs + 30 * 1000,
    }
  elseif target.language == 'python' then
    local pytest = local_bin(root, { '.venv/bin/pytest', 'venv/bin/pytest' })
      or 'pytest'
    local cmd = { pytest, '-q', '-p', 'no:cacheprovider' }
    -- A fixed order, unless the project shuffles on purpose
    if not uses_randomly(root) then
      vim.list_extend(cmd, { '-p', 'no:randomly' })
    end
    table.insert(cmd, names and rel .. '::' .. table.concat(names, '::') or rel)
    return { cmd = cmd, timeout = M.TIMEOUT }
  elseif target.language == 'js' then
    -- shortcut: the innermost name only, unanchored: it may match a test of
    -- the same name in another `describe` of the file
    local pattern = names and M.js_escape(names[#names])
    local jest = local_bin(root, { 'node_modules/.bin/jest' })
    if jest then
      local cmd = { jest, '--ci', '--runTestsByPath', rel }
      if pattern then vim.list_extend(cmd, { '-t', pattern }) end
      return { cmd = cmd, timeout = M.TIMEOUT }
    end
    local vitest = local_bin(root, { 'node_modules/.bin/vitest' })
    if vitest then
      local cmd = { vitest, 'run', rel }
      if pattern then vim.list_extend(cmd, { '-t', pattern }) end
      return { cmd = cmd, timeout = M.TIMEOUT }
    end
    return nil, 'Neither jest nor vitest in node_modules/.bin'
  end
  local modules, test = rust_module(rel)
  local cmd = { 'cargo', 'test' }
  if test then vim.list_extend(cmd, { '--test', test }) end
  -- cargo builds once; later runs only check the build is fresh
  if names then
    vim.list_extend(
      cmd,
      { '--', '--exact', table.concat(vim.list_extend(modules, names), '::') }
    )
  elseif #modules > 0 then
    vim.list_extend(cmd, { '--', table.concat(modules, '::') .. '::' })
  end
  return { cmd = cmd, timeout = M.TIMEOUT }
end

-- Reading the runs ------------------------------------------------------------

--- `line` cut to `M.MESSAGE_WIDTH`
---@param line string
---@return string
local function clip(line)
  line = vim.trim(line)
  if #line > M.MESSAGE_WIDTH then
    line = line:sub(1, M.MESSAGE_WIDTH) .. '...'
  end
  return line
end

--- The first line of the failure in `output` of `language`
---@param output string
---@param language DyFlakyLanguage
---@return string
function M.message(output, language)
  local lines = vim.split(output, '\n', { plain = true })
  if language == 'go' then
    for _, line in ipairs(lines) do
      if
        vim.trim(line) ~= ''
        and not line:match('^%s*=== ')
        and not line:match('^%s*%-%-%- ')
        and not line:match('^FAIL')
        and not line:match('^PASS')
        and not line:match('^ok%s')
      then
        return clip(line)
      end
    end
  elseif language == 'python' then
    for _, line in ipairs(lines) do
      local text = line:match('^E%s+(.+)')
      if text then return clip(text) end
    end
    for _, line in ipairs(lines) do
      local text = line:match('^FAILED%s+%S+%s+%-%s+(.+)')
      if text then return clip(text) end
    end
  elseif language == 'rust' then
    for i, line in ipairs(lines) do
      -- Older: `panicked at 'msg', file`; newer: the message on the next line
      local old = line:match("panicked at '(.-)',")
      if old then return clip(old) end
      if line:match('panicked at ') and lines[i + 1] then
        return clip(lines[i + 1])
      end
    end
  elseif language == 'js' then
    for i, line in ipairs(lines) do
      if line:match('^%s*●') then
        for j = i + 1, #lines do
          if vim.trim(lines[j]) ~= '' then return clip(lines[j]) end
        end
      end
    end
  end
  for _, line in ipairs(lines) do
    if line:match('[Ee]rror') or line:match('[Ff]ail') then
      return clip(line)
    end
  end
  for _, line in ipairs(lines) do
    if vim.trim(line) ~= '' then return clip(line) end
  end
  return 'no output'
end

--- The runs of `go test -json -count=N` in `stdout`, for top-level tests
--- `names`: run k is the k-th result of every one of them, and fails when
--- one does. Nil and why when no test ran.
---@param stdout string
---@param names string[]
---@return DyFlakyRun[]?
---@return string? err
function M.go_runs(stdout, names)
  local wanted, results, pending, other = {}, {}, {}, {}
  for _, name in ipairs(names) do
    wanted[name], results[name], pending[name] = true, {}, {}
  end
  for line in stdout:gmatch('[^\n]+') do
    local ok, event = pcall(vim.json.decode, line)
    if not ok or type(event) ~= 'table' then
      table.insert(other, line)
    elseif type(event.Test) == 'string' then
      local top = event.Test:match('^[^/]+')
      if wanted[top] then
        if event.Action == 'output' then
          table.insert(pending[top], event.Output or '')
        elseif
          event.Test == top
          and (
            event.Action == 'pass'
            or event.Action == 'fail'
            or event.Action == 'skip'
          )
        then
          local output = table.concat(pending[top])
          pending[top] = {}
          table.insert(results[top], {
            status = event.Action,
            ms = (tonumber(event.Elapsed) or 0) * 1000,
            output = output,
          })
        end
      end
    elseif event.Action == 'output' and event.Output then
      table.insert(other, (event.Output:gsub('\n$', '')))
    end
  end
  local count
  for _, name in ipairs(names) do
    count = math.min(count or math.huge, #results[name])
  end
  if not count or count == 0 then
    local why = vim.trim(table.concat(other, '\n'))
    return nil, why ~= '' and why or 'no test matched'
  end
  local runs = {}
  for k = 1, count do
    local run = { status = 'pass', ms = 0 }
    local outputs = {}
    for _, name in ipairs(names) do
      local result = results[name][k]
      run.ms = run.ms + result.ms
      if result.status ~= 'pass' then
        run.status = 'fail'
        run.message = run.message
          or (
            result.status == 'skip' and ('%s skipped'):format(name)
            or M.message(result.output, 'go')
          )
        table.insert(outputs, result.output)
      end
    end
    if run.status == 'fail' then run.output = table.concat(outputs) end
    table.insert(runs, run)
  end
  return runs
end

--- The run `result` of one command of `language` was, `ms` long; nil and
--- why when it says the test could not run at all, which is no outcome
---@param result DyRunResult
---@param language DyFlakyLanguage
---@param ms number
---@return DyFlakyRun?
---@return string? err
function M.outcome(result, language, ms)
  if result.missing then return nil, result.stderr end
  local output = result.stdout .. result.stderr
  if result.timed_out then
    return {
      status = 'timeout',
      ms = ms,
      message = ('timed out after %d s'):format(M.TIMEOUT / 1000),
      output = output,
    }
  end
  if result.cut then
    return {
      status = 'fail',
      ms = ms,
      message = ('printed more than %d bytes and was stopped'):format(
        M.MAX_BYTES
      ),
      output = output,
    }
  end
  if language == 'python' and (result.code == 4 or result.code == 5) then
    return nil,
      result.code == 5 and 'pytest collected no test'
        or 'pytest: ' .. M.message(output, language)
  elseif language == 'js' then
    if output:match('No tests found') then return nil, 'no test matched' end
    if result.code == 0 and not output:match('%d+ passed') then
      return nil, 'no test matched'
    end
  elseif language == 'rust' then
    local total, seen = 0, false
    for passed, failed in
      output:gmatch('test result: %w+%. (%d+) passed; (%d+) failed')
    do
      seen = true
      total = total + tonumber(passed) + tonumber(failed)
    end
    if not seen then
      return nil, 'cargo test ran no test: ' .. M.message(output, language)
    end
    if total == 0 then return nil, 'no test matched' end
  end
  if result.code == 0 then return { status = 'pass', ms = ms } end
  return {
    status = 'fail',
    ms = ms,
    message = M.message(output, language),
    output = output,
  }
end

--- The passes, failures, durations and verdict of `runs`
---@param runs DyFlakyRun[]
---@return DyFlakySummary
function M.summarize(runs)
  local passes, by_message, failures, durations = 0, {}, {}, {}
  for _, run in ipairs(runs) do
    table.insert(durations, run.ms)
    if run.status == 'pass' then
      passes = passes + 1
    else
      local message = run.message or run.status
      local failure = by_message[message]
      if not failure then
        failure = { message = message, count = 0, output = run.output }
        by_message[message] = failure
        table.insert(failures, failure)
      end
      failure.count = failure.count + 1
    end
  end
  table.sort(failures, function(a, b)
    if a.count ~= b.count then return a.count > b.count end
    return a.message < b.message
  end)
  table.sort(durations)
  local n = #runs
  local median
  if n > 0 then
    median = n % 2 == 1 and durations[(n + 1) / 2]
      or (durations[n / 2] + durations[n / 2 + 1]) / 2
  end
  local verdict = n == 0 and 'no run finished'
    or passes == n and 'stable pass'
    or passes == 0 and 'always fails'
    or 'flaky'
  return {
    runs = n,
    passes = passes,
    rate = n > 0 and (n - passes) / n or 0,
    failures = failures,
    min = durations[1],
    median = median,
    max = durations[n],
    verdict = verdict,
  }
end

--- `ms` as people read it
---@param ms number
---@return string
local function duration(ms)
  if ms >= 1000 then return ('%.2f s'):format(ms / 1000) end
  return ('%d ms'):format(math.floor(ms + 0.5))
end

--- The report of `summary`, of `asked` runs of `target` by `cmd`
---@param target DyFlakyTarget
---@param cmd string[]
---@param summary DyFlakySummary
---@param asked integer
---@param note? string Why it ended early
---@return string[]
function M.report(target, cmd, summary, asked, note)
  local lines = {
    ('# Flaky: %s'):format(target.label),
    '',
    ('- Verdict: **%s**'):format(summary.verdict),
    ('- Passed: %d of %d (%d%% failed)'):format(
      summary.passes,
      summary.runs,
      math.floor(summary.rate * 100 + 0.5)
    ),
  }
  if note then
    table.insert(
      lines,
      ('- Ended after %d of %d: %s'):format(summary.runs, asked, note)
    )
  end
  if summary.min then
    table.insert(
      lines,
      ('- Durations: min %s, median %s, max %s'):format(
        duration(summary.min),
        duration(summary.median),
        duration(summary.max)
      )
    )
  end
  table.insert(
    lines,
    ('- Command: `%s` in %s'):format(
      table.concat(cmd, ' '),
      vim.fn.fnamemodify(target.root, ':~')
    )
  )
  if #summary.failures > 0 then
    vim.list_extend(lines, { '', '## Failures', '' })
    for _, failure in ipairs(summary.failures) do
      table.insert(lines, ('- %dx %s'):format(failure.count, failure.message))
    end
    for _, failure in ipairs(summary.failures) do
      vim.list_extend(lines, { '', '### ' .. failure.message, '', '```' })
      local output =
        vim.split(vim.trim(failure.output or ''), '\n', { plain = true })
      for i = 1, math.min(#output, M.OUTPUT_LINES) do
        table.insert(lines, output[i])
      end
      if #output > M.OUTPUT_LINES then
        table.insert(
          lines,
          ('... %d more lines'):format(#output - M.OUTPUT_LINES)
        )
      end
      table.insert(lines, '```')
    end
  end
  return lines
end

-- Running ---------------------------------------------------------------------

---@class DyFlakyState
---@field stopped boolean
---@field process? vim.SystemObj

--- The run going on, nil when none
---@type DyFlakyState?
M.current = nil

--- Stop the run going on; the runs that finished are reported
function M.stop()
  local current = M.current
  if not current then return notify('No flaky-test run going on') end
  current.stopped = true
  local process = current.process
  if process then
    -- Each run leads a process group of its own: what it started goes too
    if process.pid then pcall(vim.uv.kill, -process.pid, 'sigterm') end
    pcall(process.kill, process, 'sigterm')
  end
end

--- Show the report of `runs` and say the verdict
---@param target DyFlakyTarget
---@param command DyFlakyCommand
---@param runs DyFlakyRun[]
---@param asked integer
---@param note? string
local function finish(target, command, runs, asked, note)
  M.current = nil
  local summary = M.summarize(runs)
  require('util.scratch').open(
    M.report(target, command.cmd, summary, asked, note),
    {
      name = 'dyflaky://' .. target.label,
      filetype = 'markdown',
    }
  )
  local level = summary.verdict == 'stable pass' and vim.log.levels.INFO
    or summary.verdict == 'flaky' and vim.log.levels.WARN
    or vim.log.levels.ERROR
  notify(
    ('%s: %s, %d of %d passed'):format(
      target.label,
      summary.verdict,
      summary.passes,
      summary.runs
    ),
    level,
    { id = M.NOTIFY_ID }
  )
end

--- Say that `target` could not run, and why: no outcome
---@param target DyFlakyTarget
---@param err string
local function abort(target, err)
  M.current = nil
  notify(
    ('%s not run: %s'):format(target.label, err),
    vim.log.levels.ERROR,
    { id = M.NOTIFY_ID }
  )
end

--- Run `target` `runs` times in the background
---@param target DyFlakyTarget
---@param runs integer
function M.start(target, runs)
  local command, err = M.command(target, runs)
  if not command then return abort(target, err or 'no command') end
  ---@type DyFlakyState
  local state = { stopped = false }
  M.current = state
  local opts = {
    cwd = target.root,
    timeout = command.timeout,
    max_bytes = command.json and M.MAX_BYTES * runs or M.MAX_BYTES,
    detach = true,
  }
  if command.json then
    notify(
      ('%s: %d runs in one go test'):format(target.label, runs),
      nil,
      { id = M.NOTIFY_ID }
    )
    state.process = system.run(command.cmd, opts, function(result)
      if result.missing then return abort(target, result.stderr) end
      local done, why = M.go_runs(result.stdout, target.names)
      if not done then
        if state.stopped then
          return finish(target, command, {}, runs, 'stopped')
        end
        return abort(target, why or 'no test ran')
      end
      local note = state.stopped and 'stopped' or nil
      if #done < runs and not state.stopped then
        if result.timed_out or result.stdout:match('test timed out after') then
          table.insert(done, {
            status = 'timeout',
            ms = M.TIMEOUT,
            message = 'timed out',
          })
          note = 'timed out'
        elseif result.cut then
          note = ('more than %d bytes of output'):format(opts.max_bytes)
        else
          note = 'go test ended early'
        end
      end
      finish(target, command, done, runs, note)
    end)
    return
  end
  local done = {}
  local function step()
    if state.stopped then
      return finish(target, command, done, runs, 'stopped')
    end
    if #done == runs then return finish(target, command, done, runs) end
    local passed =
      #vim.tbl_filter(function(r) return r.status == 'pass' end, done)
    notify(
      ('%s: run %d of %d, %d passed, %d failed'):format(
        target.label,
        #done + 1,
        runs,
        passed,
        #done - passed
      ),
      nil,
      { id = M.NOTIFY_ID }
    )
    local began = vim.uv.hrtime()
    state.process = system.run(command.cmd, opts, function(result)
      state.process = nil
      -- A run stopped from here is no outcome
      if state.stopped then
        return finish(target, command, done, runs, 'stopped')
      end
      local run, why =
        M.outcome(result, target.language, (vim.uv.hrtime() - began) / 1e6)
      if not run then return abort(target, why or 'no outcome') end
      table.insert(done, run)
      step()
    end)
  end
  step()
end

--- `:DyFlaky [file|stop]`: run the test under the cursor, or the file's
--- tests, `count` times (`M.RUNS` when 0 or nil)
---@param arg? string
---@param count? integer
function M.run(arg, count)
  if arg == 'stop' then return M.stop() end
  if arg and arg ~= '' and arg ~= 'file' then
    return notify(('Unknown argument: %s'):format(arg), vim.log.levels.ERROR)
  end
  if M.current then
    return notify(
      'A flaky-test run is going on: `:DyFlaky stop` ends it',
      vim.log.levels.WARN
    )
  end
  local runs = (count and count > 0) and count or M.RUNS
  local target, err = M.target(vim.api.nvim_get_current_buf(), arg == 'file')
  if not target then return notify(err or 'No test', vim.log.levels.ERROR) end
  local question = ('Run %s %d times?\nThe tests run code of the project in %s, as you.'):format(
    target.label,
    runs,
    vim.fn.fnamemodify(target.root, ':~')
  )
  if not require('util.trust').ask('flaky', target.root, question) then
    return notify('Not run: the project is not trusted', vim.log.levels.WARN)
  end
  M.start(target, runs)
end

return M
