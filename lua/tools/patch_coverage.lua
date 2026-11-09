--- Patch coverage: how much of what the change adds or modifies the tests run
---
--- The change is every line added or modified since the merge base of `HEAD`
--- with the default branch (or a ref given), committed or not, and every line
--- of an untracked file; `tools.testaffected` finds the merge base. The
--- coverage is the newest report the project holds: LCOV, Cobertura XML, a Go
--- cover profile or coverage.py JSON, in the project root or in the
--- directories crazy-coverage searches. Only the changed lines the report
--- calls executable count, as diff-cover and Codecov count them; a changed
--- file the report does not know is named, not counted. A report older than a
--- changed file it covers is stale, and said to be.
local M = {}

local notify = require('util.notify').titled('Patch Coverage')
local system = require('util.system')

M.NS = vim.api.nvim_create_namespace('dy_patch_coverage')

--- Title of the quickfix list
M.TITLE = 'Patch coverage'

--- Milliseconds git may take
M.TIMEOUT = 60 * 1000

--- Output kept of git, and the largest report read
M.MAX_BYTES = 64 * 1024 * 1024

--- Searched besides the root, when crazy-coverage is not configured
M.DIRS = {
  'coverage/bats',
  'target/tarpaulin',
  'target/coverage',
  'build/coverage',
  'coverage',
  'build',
}

--- Report names looked for in the root and each of those directories
M.NAMES = {
  'lcov.info',
  '*.lcov',
  'coverage.xml',
  'cobertura.xml',
  'cobertura-coverage.xml',
  'coverage.out',
  'cover.out',
  'coverage.json',
}

--- How to make a report, said when there is none
M.HOWTO =
  'make one with `go test -coverprofile=coverage.out ./...`, `pytest --cov --cov-report=xml`, `jest --coverage`, `cargo llvm-cov --lcov --output-path lcov.info` (`coverage xml` turns a `.coverage` into one); `<leader>tc` then shows the whole of it'

--- Executable lines of each file, by absolute path, to their hit count
---@alias DyCoverage table<string, table<integer, integer>>

--- Changed lines of each file relative to the root; `true` for every line
---@alias DyChangedLines table<string, table<integer, true>|true>

---@class DyPatchFile
---@field path string Relative to the root
---@field covered integer
---@field total integer Changed lines the report calls executable
---@field uncovered integer[]
---@field known boolean The report covers the file
---@field stale boolean Changed after the report was written

---@class DyPatchResult
---@field covered integer
---@field total integer
---@field files DyPatchFile[]
---@field stale boolean

local function unescape(text)
  return (
    text
      :gsub('&lt;', '<')
      :gsub('&gt;', '>')
      :gsub('&quot;', '"')
      :gsub('&apos;', "'")
      :gsub('&amp;', '&')
  )
end

--- `name` as an absolute path: tried under each of `dirs` (relative to
--- `root`) in turn, the first that exists, else under `root`
---@param root string
---@param name string
---@param dirs? string[]
---@return string
local function resolve(root, name, dirs)
  if name:sub(1, 1) == '/' then
    return vim.uv.fs_realpath(name) or vim.fs.normalize(name)
  end
  for _, dir in ipairs(dirs or {}) do
    local base = dir:sub(1, 1) == '/' and dir or vim.fs.joinpath(root, dir)
    local real = vim.uv.fs_realpath(vim.fs.joinpath(base, name))
    if real then return real end
  end
  local path = vim.fs.joinpath(root, name)
  return vim.uv.fs_realpath(path) or vim.fs.normalize(path)
end

--- Record `hits` for line `lnum` of `path`, the highest a line is given
---@param data DyCoverage
local function hit(data, path, lnum, hits)
  local lines = data[path] or {}
  data[path] = lines
  lines[lnum] = math.max(lines[lnum] or 0, hits)
end

--- Each format: whether `text` is one, and its parser
---@type { name: string, is: fun(text: string): boolean, parse: fun(text: string, root: string): DyCoverage }[]
M.FORMATS = {
  {
    name = 'LCOV',
    is = function(text)
      return text:find('^%s*TN:') ~= nil or text:find('^%s*SF:') ~= nil
    end,
    parse = function(text, root)
      local data, path = {}, nil
      for line in vim.gsplit(text, '\n', { plain = true }) do
        local file = line:match('^SF:(.-)%s*$')
        if file then
          path = resolve(root, file)
        else
          local lnum, hits = line:match('^DA:(%d+),(%d+)')
          if lnum and path then
            hit(data, path, tonumber(lnum), tonumber(hits))
          end
        end
      end
      return data
    end,
  },
  {
    name = 'Go',
    is = function(text) return text:find('^mode: %a+') ~= nil end,
    parse = function(text, root)
      -- Paths are import paths: the module of `go.mod` stands for the root
      local module
      local mod = io.open(vim.fs.joinpath(root, 'go.mod'))
      if mod then
        module = mod:read('*a'):match('module%s+(%S+)')
        mod:close()
      end
      local data = {}
      for line in vim.gsplit(text, '\n', { plain = true }) do
        local file, first, last, last_col, hits =
          line:match('^(.+):(%d+)%.%d+,(%d+)%.(%d+) %d+ (%d+)$')
        if file then
          if module and vim.startswith(file, module .. '/') then
            file = file:sub(#module + 2)
          end
          local path = resolve(root, file)
          -- A block ending at column 1 holds nothing of that line
          local stop = tonumber(last) - (last_col == '1' and 1 or 0)
          for lnum = tonumber(first), math.max(tonumber(first), stop) do
            hit(data, path, lnum, tonumber(hits))
          end
        end
      end
      return data
    end,
  },
  {
    name = 'Cobertura',
    is = function(text) return text:find('<coverage[%s>]') ~= nil end,
    parse = function(text, root)
      local sources = {}
      for source in text:gmatch('<source>%s*(.-)%s*</source>') do
        table.insert(sources, unescape(source))
      end
      local data, path = {}, nil
      for tag, attrs in text:gmatch('<(%a+)(%s[^>]*)>') do
        if tag == 'class' then
          local file = attrs:match('filename="([^"]*)"')
          path = file and resolve(root, unescape(file), sources)
        elseif tag == 'line' and path then
          local lnum = attrs:match('number="(%d+)"')
          local hits = attrs:match('hits="(%d+)"')
          if lnum and hits then
            hit(data, path, tonumber(lnum), tonumber(hits))
          end
        end
      end
      return data
    end,
  },
  {
    name = 'coverage.py JSON',
    is = function(text)
      return text:find('^%s*{') ~= nil and text:find('"executed_lines"') ~= nil
    end,
    parse = function(text, root)
      local data = {}
      local ok, report = pcall(vim.json.decode, text)
      if not ok or type(report) ~= 'table' or type(report.files) ~= 'table' then
        error('not a coverage.py JSON report')
      end
      for file, entry in pairs(report.files) do
        local path = resolve(root, file)
        for _, lnum in ipairs(entry.missing_lines or {}) do
          hit(data, path, lnum, 0)
        end
        for _, lnum in ipairs(entry.executed_lines or {}) do
          hit(data, path, lnum, 1)
        end
      end
      return data
    end,
  },
}

--- Read the report at `path`
---@param path string
---@param root string
---@return DyCoverage? data
---@return string? format_or_err The format, or why it was not read
function M.read(path, root)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, 'no such file' end
  if stat.size > M.MAX_BYTES then
    return nil, ('larger than %d bytes'):format(M.MAX_BYTES)
  end
  local file = io.open(path, 'rb')
  if not file then return nil, 'cannot be read' end
  local text = file:read('*a')
  file:close()
  for _, format in ipairs(M.FORMATS) do
    if format.is(text:sub(1, 4096)) then
      local ok, data = pcall(format.parse, text, root)
      if not ok then
        return nil, ('not a readable %s report: %s'):format(format.name, data)
      end
      return data, format.name
    end
  end
  return nil, 'not LCOV, Cobertura, a Go cover profile or coverage.py JSON'
end

--- The reports of the project at `root`, the newest first
---@param root string
---@return { path: string, mtime: integer }[]
function M.reports(root)
  local ok, opts = pcall(
    function() return require('util.plugin').opts('crazy-coverage.nvim') end
  )
  local dirs = vim.list_extend({ '.' }, ok and opts.coverage_dirs or M.DIRS)
  local found, seen = {}, {}
  for _, dir in ipairs(dirs) do
    for _, name in ipairs(M.NAMES) do
      for _, path in
        ipairs(vim.fn.glob(vim.fs.joinpath(root, dir, name), true, true))
      do
        path = vim.fs.normalize(path)
        local stat = vim.uv.fs_stat(path)
        if stat and stat.type == 'file' and not seen[path] then
          seen[path] = true
          table.insert(found, { path = path, mtime = stat.mtime.sec })
        end
      end
    end
  end
  table.sort(found, function(a, b)
    if a.mtime ~= b.mtime then return a.mtime > b.mtime end
    return a.path < b.path
  end)
  return found
end

--- The changed lines of `git diff -U0` output
---@param diff string
---@return DyChangedLines
function M.parse_diff(diff)
  local changed, file = {}, nil
  for line in vim.gsplit(diff, '\n', { plain = true }) do
    local target = line:match('^%+%+%+ (.*)$')
    if target then
      -- `/dev/null`: the file is gone, and none of its lines count
      file = target:match('^b/(.*)$')
      file = file and file:gsub('\t$', '')
    elseif file then
      local start, count = line:match('^@@ %-[%d,]+ %+(%d+),?(%d*) @@')
      if start then
        count = count == '' and 1 or tonumber(count)
        local lines = changed[file] or {}
        changed[file] = lines
        for lnum = tonumber(start), tonumber(start) + count - 1 do
          lines[lnum] = true
        end
      end
    end
  end
  return changed
end

local function git(root, args, on_done)
  system.run(
    vim.list_extend({ 'git', '-c', 'core.quotePath=false' }, args),
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      if result.cut then
        return on_done(
          nil,
          ('git printed more than %d bytes'):format(M.MAX_BYTES)
        )
      end
      if result.code ~= 0 then
        return on_done(nil, system.failure(result, 'git ' .. args[1]))
      end
      on_done(result.stdout)
    end
  )
end

--- The lines changed under `root` since the merge base with `ref` or the
--- default branch: the diff to the working tree, and untracked files whole
---@param root string
---@param ref? string
---@param on_done fun(changed?: DyChangedLines, err?: string, base?: string)
function M.changed(root, ref, on_done)
  if ref and ref:sub(1, 1) == '-' then
    return on_done(nil, ('Not a ref: %s'):format(ref))
  end
  require('tools.testaffected').base(root, ref, function(base, err)
    if not base then return on_done(nil, err) end
    git(root, {
      'diff',
      '-U0',
      '--no-color',
      '--no-ext-diff',
      '--no-renames',
      '--src-prefix=a/',
      '--dst-prefix=b/',
      '--relative',
      base,
      '--',
    }, function(diff, diff_err)
      if not diff then return on_done(nil, diff_err) end
      git(
        root,
        { 'ls-files', '-z', '--others', '--exclude-standard' },
        function(others, others_err)
          if not others then return on_done(nil, others_err) end
          local changed = M.parse_diff(diff)
          for _, file in
            ipairs(vim.split(others, '\0', { plain = true, trimempty = true }))
          do
            changed[file] = true
          end
          on_done(changed, nil, base)
        end
      )
    end)
  end)
end

--- The patch coverage of `changed` by `data`, a report written at
--- `report_mtime`
---@param root string
---@param changed DyChangedLines
---@param data DyCoverage
---@param report_mtime integer
---@return DyPatchResult
function M.compute(root, changed, data, report_mtime)
  local result = { covered = 0, total = 0, files = {}, stale = false }
  local rels = vim.tbl_keys(changed)
  table.sort(rels)
  for _, rel in ipairs(rels) do
    local path = vim.fs.joinpath(root, rel)
    local hits = data[vim.uv.fs_realpath(path) or path]
    local file = {
      path = rel,
      covered = 0,
      total = 0,
      uncovered = {},
      known = hits ~= nil,
      stale = false,
    }
    if hits then
      local stat = vim.uv.fs_stat(path)
      file.stale = stat ~= nil and stat.mtime.sec > report_mtime
      result.stale = result.stale or file.stale
      local lines = changed[rel]
      for lnum, count in pairs(hits) do
        if lines == true or lines[lnum] then
          file.total = file.total + 1
          if count > 0 then
            file.covered = file.covered + 1
          else
            table.insert(file.uncovered, lnum)
          end
        end
      end
      table.sort(file.uncovered)
      result.covered = result.covered + file.covered
      result.total = result.total + file.total
    end
    table.insert(result.files, file)
  end
  return result
end

--- `covered` of `total` as a percentage, `-` when nothing counts
---@param covered integer
---@param total integer
---@return string
function M.percent(covered, total)
  if total == 0 then return '-' end
  return ('%.1f%%'):format(covered * 100 / total)
end

--- The summary of `result`, one line per file
---@param result DyPatchResult
---@param report string
---@param format string
---@param base string
---@return string[]
function M.summary(result, report, format, base)
  local lines = {
    ('Patch coverage %s: %d of %d changed executable lines since %s'):format(
      M.percent(result.covered, result.total),
      result.covered,
      result.total,
      base:sub(1, 8)
    ),
    ('Report: %s (%s)'):format(vim.fn.fnamemodify(report, ':~:.'), format),
  }
  if result.stale then
    table.insert(
      lines,
      'STALE: files marked * changed after the report was written; run the tests with coverage again'
    )
  end
  table.insert(lines, '')
  local unknown = {}
  for _, file in ipairs(result.files) do
    if not file.known then
      table.insert(unknown, file.path)
    elseif file.total > 0 then
      table.insert(
        lines,
        ('%7s %4d/%-4d %s%s'):format(
          M.percent(file.covered, file.total),
          file.covered,
          file.total,
          file.path,
          file.stale and ' *' or ''
        )
      )
    end
  end
  if #unknown > 0 then
    table.insert(lines, '')
    table.insert(lines, 'Not in the report, not counted:')
    for _, path in ipairs(unknown) do
      table.insert(lines, '  ' .. path)
    end
  end
  return lines
end

--- Remove the marks, and the quickfix list when it is ours
function M.clear()
  vim.diagnostic.reset(M.NS)
  if vim.fn.getqflist({ title = 0 }).title == M.TITLE then
    vim.fn.setqflist({}, 'r', { title = M.TITLE, items = {} })
  end
  M.shown = false
end

--- Show `result`: the summary, the uncovered changed lines in the quickfix
--- list and as hints in their buffers
---@param root string
---@param result DyPatchResult
---@param report string
---@param format string
---@param base string
function M.show(root, result, report, format, base)
  M.clear()
  local items = {}
  for _, file in ipairs(result.files) do
    for _, lnum in ipairs(file.uncovered) do
      table.insert(items, {
        filename = vim.fs.joinpath(root, file.path),
        lnum = lnum,
        col = 1,
        text = 'changed line not covered by the tests',
        type = 'I',
      })
    end
  end
  vim.fn.setqflist({}, ' ', { title = M.TITLE, items = items })
  local by_buf = {}
  for _, diagnostic in ipairs(vim.diagnostic.fromqflist(vim.fn.getqflist())) do
    diagnostic.severity = vim.diagnostic.severity.HINT
    diagnostic.source = 'patch coverage'
    by_buf[diagnostic.bufnr] = by_buf[diagnostic.bufnr] or {}
    table.insert(by_buf[diagnostic.bufnr], diagnostic)
  end
  for buf, diagnostics in pairs(by_buf) do
    vim.diagnostic.set(M.NS, buf, diagnostics)
  end
  M.shown = true
  require('util.scratch').open(M.summary(result, report, format, base), {
    name = 'DyPatchCoverage',
    split = 'horizontal',
  })
  notify(
    ('%s of the changed lines covered, %d uncovered in the quickfix list%s'):format(
      M.percent(result.covered, result.total),
      #items,
      result.stale and '; the report is STALE' or ''
    ),
    result.stale and vim.log.levels.WARN or vim.log.levels.INFO
  )
end

--- Work out and show the patch coverage of the project of the buffer
---@param ref? string
function M.run(ref)
  local root = require('util.root')()
  root = vim.uv.fs_realpath(root) or root
  local reports = M.reports(root)
  if #reports == 0 then
    return notify(
      ('No coverage report in %s: %s'):format(
        vim.fn.fnamemodify(root, ':~'),
        M.HOWTO
      ),
      vim.log.levels.WARN
    )
  end
  local report, data, format = reports[1], nil, nil
  data, format = M.read(report.path, root)
  if not data then
    return notify(
      ('Coverage report %s: %s'):format(
        vim.fn.fnamemodify(report.path, ':~'),
        format
      ),
      vim.log.levels.ERROR
    )
  end
  M.changed(root, ref, function(changed, err, base)
    if not changed or not base then
      return notify(
        ('Cannot tell what changed: %s'):format(err),
        vim.log.levels.ERROR
      )
    end
    if vim.tbl_isempty(changed) then
      return notify(('Nothing changed since %s'):format(base:sub(1, 8)))
    end
    -- The report itself is often untracked, and no source
    changed[report.path:sub(#root + 2)] = nil
    local result = M.compute(root, changed, data, report.mtime)
    M.show(root, result, report.path, format --[[@as string]], base)
  end)
end

--- Clear the marks when shown, else work them out
function M.toggle()
  if M.shown then return M.clear() end
  M.run()
end

return M
