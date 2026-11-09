--- Mutation testing: the code the tests run but do not check
---
--- The step after coverage. A mutation tool changes the code one small way
--- at a time (`>` to `>=`, `+` to `-`, a return value to a constant) and runs
--- the tests on each change, a mutant; one they still pass on survived, so
--- the line it changed is run but not checked. Each project gets the tool of
--- its language: mutmut for Python, Stryker for JavaScript and TypeScript
--- (the project's own install), gremlins for Go, cargo-mutants for Rust. A
--- run takes minutes, so it runs in a terminal split; once it exits, the
--- mutants that survived become warnings, those no test reached or that
--- timed out hints, in namespace `dy_mutate` and in the quickfix list.
---
--- gremlins is the Go tool as it is released and maintained, reads the
--- coverage first so it only tests what a test reaches, and writes JSON;
--- go-mutesting has no machine-readable report.
local M = {}

local notify = require('util.notify').titled('Mutate')

--- The namespace of the diagnostics
M.NS = vim.api.nvim_create_namespace('dy_mutate')

--- Bytes read of a report; Stryker's holds the source of every file
M.MAX_BYTES = 32 * 1024 * 1024

--- Lines of the terminal split
M.HEIGHT = 12

--- Title of the quickfix list
M.TITLE = 'Mutants'

--- The tool and project of the last run
---@type { tool: DyMutateTool, root: string }?
M.last = nil

---@alias DyMutantStatus 'survived'|'nocoverage'|'timeout'|'killed'|'other'

---@class DyMutant
---@field file string Relative to the project, or absolute
---@field lnum integer
---@field col? integer
---@field end_lnum? integer
---@field end_col? integer
---@field status DyMutantStatus
---@field text string The mutation

--- How each status reads, and its quickfix type: `W` a warning, `I` a hint
local SHOWN = {
  survived = { 'survived', 'W' },
  nocoverage = { 'no test reaches it', 'I' },
  timeout = { 'timed out', 'I' },
}

--- The text of `path`, or nil and why
---@param path string
---@return string?
---@return string?
local function read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, ('No report at %s'):format(path) end
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
    return nil, ('%s is not a JSON report'):format(path)
  end
  return value
end

--- The lines of `path`, none when it cannot be read
---@param path string
---@return string[]
local function lines_of(path)
  local text = read(path)
  return text and vim.split(text, '\n', { plain = true }) or {}
end

-- Stryker ---------------------------------------------------------------------

local STRYKER = {
  Survived = 'survived',
  NoCoverage = 'nocoverage',
  Timeout = 'timeout',
  Killed = 'killed',
}

--- The mutants of Stryker's `mutation.json`, the mutation-testing-report
--- schema: files, each with its source and mutants at 1-based positions
---@param report table
---@return DyMutant[]
function M.stryker(report)
  local mutants = {}
  for file, entry in pairs(report.files or {}) do
    local source = vim.split(entry.source or '', '\n', { plain = true })
    for _, mutant in ipairs(entry.mutants or {}) do
      local start = mutant.location and mutant.location.start or {}
      local stop = mutant.location and mutant.location['end'] or {}
      local text = mutant.mutatorName or 'mutant'
      local line = source[start.line or 0]
      if line and stop.line == start.line and mutant.replacement then
        text = ('%s: %s -> %s'):format(
          text,
          line:sub(start.column, stop.column - 1),
          vim.split(mutant.replacement, '\n')[1]
        )
      end
      table.insert(mutants, {
        file = file,
        lnum = start.line or 1,
        col = start.column,
        end_lnum = stop.line,
        end_col = stop.column,
        status = STRYKER[mutant.status] or 'other',
        text = text,
      })
    end
  end
  return mutants
end

-- cargo-mutants ---------------------------------------------------------------

local CARGO = {
  MissedMutant = 'survived',
  Timeout = 'timeout',
  CaughtMutant = 'killed',
}

--- The mutants of cargo-mutants' `mutants.out/outcomes.json`
---@param report table
---@return DyMutant[]
function M.cargo_mutants(report)
  local mutants = {}
  for _, outcome in ipairs(report.outcomes or {}) do
    -- The first is the baseline, `"Baseline"`, not a mutant
    local mutant = type(outcome.scenario) == 'table' and outcome.scenario.Mutant
    if mutant then
      local span = mutant.span or {}
      local start, stop = span.start or {}, span['end'] or {}
      table.insert(mutants, {
        file = mutant.file,
        lnum = start.line or 1,
        col = start.column,
        end_lnum = stop.line,
        end_col = stop.column,
        status = CARGO[outcome.summary] or 'other',
        -- `src/lib.rs:6:7: replace > with >= in is_big`
        text = (mutant.name or ''):match('^.-:%d+:%d+: (.+)$')
          or mutant.name
          or 'mutant',
      })
    end
  end
  return mutants
end

-- gremlins --------------------------------------------------------------------

local GREMLINS = {
  LIVED = 'survived',
  ['NOT COVERED'] = 'nocoverage',
  ['TIMED OUT'] = 'timeout',
  KILLED = 'killed',
}

--- The mutants of a gremlins `--output` report, its files relative to the
--- module
---@param report table
---@return DyMutant[]
function M.gremlins(report)
  local mutants = {}
  for _, file in ipairs(report.files or {}) do
    for _, mutation in ipairs(file.mutations or {}) do
      table.insert(mutants, {
        file = file.file_name,
        lnum = mutation.line or 1,
        col = mutation.column,
        status = GREMLINS[mutation.status] or 'other',
        -- `CONDITIONALS_BOUNDARY`: it says the kind, not the change
        text = (mutation.type or 'mutant'):lower():gsub('_', ' '),
      })
    end
  end
  return mutants
end

-- mutmut ----------------------------------------------------------------------

--- mutmut's exit codes of a mutant's test run, as its `status_by_exit_code`
---@param code any
---@return DyMutantStatus
local function mutmut_status(code)
  if code == 0 then return 'survived' end
  if code == 1 or code == 3 or code == 37 then return 'killed' end
  if code == 5 or code == 33 then return 'nocoverage' end
  if vim.tbl_contains({ 36, 24, -24, 152, 255 }, code) then return 'timeout' end
  return 'other'
end

--- `ǁ`, which separates the class from the method in a mutmut name
local SEP = '\199\129'

--- The line of `source` defining the function mutmut calls `fn` (`x_f`, or
--- `xǁClassǁmethod`), whose copy in the mutants file starts with `def_line`
---@param source string[]
---@param fn string
---@param def_line string
---@return integer?
function M.find_def(source, fn, def_line)
  local plain = fn:match('^x_(.*)$') or fn:match('.*' .. SEP .. '(.*)$')
  local class = fn:match('^x' .. SEP .. '(.-)' .. SEP)
  if not plain then return nil end
  local wanted =
    vim.trim((def_line:gsub(vim.pesc(fn .. '__mutmut_orig'), plain, 1)))
  local first = 1
  if class then
    first = nil
    for i, line in ipairs(source) do
      if line:match('^%s*class%s+' .. vim.pesc(class) .. '[%s(:]') then
        first = i + 1
        break
      end
    end
    if not first then return nil end
  end
  for i = first, #source do
    if vim.trim(source[i]) == wanted then return i end
  end
end

--- The mutants of one file mutmut mutated
---
--- mutmut keeps, beside a copy of the file under `mutants/`, the exit code
--- of each mutant (`.meta`) and the lines of the original and of each
--- mutated copy of a function in that copy (`.spans`). The changed line is
--- where the two copies differ, counted from the function's `def` in the
--- source.
---@param rel string The file, relative to the project
---@param meta table Its `.meta`
---@param spans table<string, integer[]> The `spans` of its `.spans`
---@param mutated string[] Its copy under `mutants/`
---@param source string[] The file
---@return DyMutant[]
function M.mutmut_file(rel, meta, spans, mutated, source)
  local mutants = {}
  for key, code in pairs(meta.exit_code_by_key or {}) do
    -- `calc.x_is_big__mutmut_2`: no dot in the name of a function or class
    local name = key:match('[^.]+$')
    local fn = name:match('^(.*)__mutmut_%d+$')
    local mutant = {
      file = rel,
      lnum = 1,
      status = mutmut_status(code),
      text = key,
    }
    local o, s = fn and spans[fn .. '__mutmut_orig'], spans[name]
    if o and s then
      local a = vim.list_slice(mutated, o[1], o[2])
      -- Named as the original, so only the mutation differs
      local b = vim.tbl_map(
        function(line)
          return (line:gsub(vim.pesc(name), fn .. '__mutmut_orig', 1))
        end,
        vim.list_slice(mutated, s[1], s[2])
      )
      local hunk = vim.diff(
        table.concat(a, '\n') .. '\n',
        table.concat(b, '\n') .. '\n',
        { result_type = 'indices' }
      )[1]
      local def_i
      for i, line in ipairs(a) do
        if line:find(fn .. '__mutmut_orig(', 1, true) then
          def_i = i
          break
        end
      end
      local at = def_i and M.find_def(source, fn, a[def_i])
      if hunk and at then
        local before = hunk[2] > 0 and a[hunk[1]] or ''
        local after = hunk[4] > 0 and b[hunk[3]] or ''
        mutant.lnum = at + hunk[1] - def_i
        local col = 1
        while col <= #before and before:sub(col, col) == after:sub(col, col) do
          col = col + 1
        end
        mutant.col = col
        mutant.text = ('%s -> %s (%s)'):format(
          vim.trim(before),
          after == '' and '(removed)' or vim.trim(after),
          key
        )
      end
    end
    table.insert(mutants, mutant)
  end
  return mutants
end

--- The mutants of mutmut's `mutants/` directory under `root`
---@param root string
---@return DyMutant[]?
---@return string?
function M.read_mutmut(root)
  local dir = vim.fs.joinpath(root, 'mutants')
  local metas = vim.fn.isdirectory(dir) == 1
      and vim.fs.find(
        function(name) return name:match('%.py%.meta$') ~= nil end,
        { path = dir, type = 'file', limit = math.huge }
      )
    or {}
  if #metas == 0 then
    return nil,
      ('No mutmut results in %s'):format(vim.fn.fnamemodify(dir, ':~'))
  end
  table.sort(metas)
  local mutants = {}
  for _, path in ipairs(metas) do
    local rel = path:sub(#dir + 2, -#'.meta' - 1)
    local meta, err = read_json(path)
    if not meta then return nil, err end
    local spans = read_json(vim.fs.joinpath(dir, rel .. '.spans')) or {}
    vim.list_extend(
      mutants,
      M.mutmut_file(
        rel,
        meta,
        spans.spans or {},
        lines_of(vim.fs.joinpath(dir, rel)),
        lines_of(vim.fs.joinpath(root, rel))
      )
    )
  end
  return mutants
end

--- The mutmut module of `rel`, as mutmut names it: `src/` and `__init__`
--- dropped
---@param rel string
---@return string
function M.python_module(rel)
  local module = rel:gsub('%.py$', ''):gsub('/', '.'):gsub('^src%.', '')
  return (module:gsub('%.__init__$', ''))
end

-- The tools -------------------------------------------------------------------

--- Where the gremlins report of `root` goes, outside the project
---@param root string
---@return string
local function gremlins_report(root)
  return vim.fs.joinpath(
    vim.fn.stdpath('cache'),
    'dyneo',
    'mutate',
    vim.fn.sha256(root):sub(1, 16) .. '-gremlins.json'
  )
end

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

---@class DyMutateTool
---@field name string
---@field filetypes string[] Of the buffers it is for
---@field markers string[] Files at the root of a project it is for
---@field mason? string Its Mason package; none for the project's own install
---@field missing? string What to do when it is not installed, without Mason
---@field ok integer[] Exit codes of a run that went through
---@field cmd fun(root: string, rel?: string): string[] Of the project, or of `rel` alone
---@field read fun(root: string): DyMutant[]?, string?
---@field after? fun(root: string, rel?: string) Once a run went through

--- The tools, in the order a project of several languages tries them
---@type DyMutateTool[]
M.TOOLS = {
  {
    name = 'mutmut',
    filetypes = { 'python' },
    markers = { 'pyproject.toml', 'setup.cfg', 'setup.py' },
    mason = 'mutmut',
    ok = { 0 },
    -- The project's own, which imports its dependencies, before Mason's
    cmd = function(root, rel)
      local cmd = {
        local_bin(root, { '.venv/bin/mutmut', 'venv/bin/mutmut' }, 'mutmut'),
        'run',
      }
      if rel then
        local module = M.python_module(rel)
        vim.list_extend(cmd, { module .. '.x_*', module .. '.x' .. SEP .. '*' })
      end
      return cmd
    end,
    read = function(root) return M.read_mutmut(root) end,
  },
  {
    name = 'stryker',
    filetypes = {
      'javascript',
      'javascriptreact',
      'typescript',
      'typescriptreact',
      'vue',
      'svelte',
    },
    markers = { 'package.json' },
    missing = 'Stryker is not installed in the project: `npm install --save-dev @stryker-mutator/core`',
    ok = { 0 },
    -- `json` joins the reporters it has by default
    cmd = function(root, rel)
      local cmd = {
        local_bin(root, { 'node_modules/.bin/stryker' }, 'stryker'),
        'run',
        '--reporters',
        'clear-text,progress,html,json',
      }
      if rel then vim.list_extend(cmd, { '--mutate', rel }) end
      return cmd
    end,
    read = function(root)
      local report, err =
        read_json(vim.fs.joinpath(root, 'reports/mutation/mutation.json'))
      if not report then return nil, err end
      return M.stryker(report)
    end,
  },
  {
    name = 'gremlins',
    filetypes = { 'go' },
    markers = { 'go.mod' },
    mason = 'gremlins',
    ok = { 0, 10, 11 }, -- 10 and 11: under a threshold of its configuration
    -- Its path is a package directory, not a file
    cmd = function(root, rel)
      local out = gremlins_report(root)
      vim.fn.mkdir(vim.fs.dirname(out), 'p')
      local cmd = { 'gremlins', 'unleash', '--output', out }
      if rel then table.insert(cmd, './' .. vim.fs.dirname(rel)) end
      return cmd
    end,
    -- The files of a run on a package are relative to it: made relative to
    -- the module, so a later `load` places them
    after = function(root, rel)
      local dir = rel and vim.fs.dirname(rel)
      if not dir or dir == '.' then return end
      local path = gremlins_report(root)
      local report = read_json(path)
      if not report then return end
      for _, file in ipairs(report.files or {}) do
        file.file_name = dir .. '/' .. file.file_name
      end
      vim.fn.writefile({ vim.json.encode(report) }, path)
    end,
    read = function(root)
      local report, err = read_json(gremlins_report(root))
      if not report then return nil, err end
      return M.gremlins(report)
    end,
  },
  {
    name = 'cargo-mutants',
    filetypes = { 'rust' },
    markers = { 'Cargo.toml' },
    mason = 'cargo-mutants',
    ok = { 0, 2, 3 }, -- 2: mutants missed, 3: some timed out
    cmd = function(_, rel)
      local cmd = { 'cargo-mutants', 'mutants' }
      if rel then vim.list_extend(cmd, { '--file', rel }) end
      return cmd
    end,
    read = function(root)
      local report, err =
        read_json(vim.fs.joinpath(root, 'mutants.out/outcomes.json'))
      if not report then return nil, err end
      return M.cargo_mutants(report)
    end,
  },
}

--- The tool for buffer `buf` and the root of its project: the one of its
--- filetype; from a terminal or another buffer of no file, the project of
--- the last run; else the first whose files are at the root of the project
---@param buf integer
---@return DyMutateTool?
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
  local root = require('util.root')()
  root = vim.uv.fs_realpath(root) or root
  for _, tool in ipairs(M.TOOLS) do
    for _, marker in ipairs(tool.markers) do
      if vim.uv.fs_stat(vim.fs.joinpath(root, marker)) then
        return tool, root
      end
    end
  end
end

-- Showing ---------------------------------------------------------------------

--- Clear the diagnostics, and the quickfix list when it is ours
function M.clear()
  vim.diagnostic.reset(M.NS)
  if vim.fn.getqflist({ title = 1 }).title == M.TITLE then
    vim.fn.setqflist({}, 'r', { title = M.TITLE, items = {} })
    vim.cmd('cclose')
  end
end

--- Mark the mutants that were not killed: diagnostics, the quickfix list,
--- and a count of every status
---@param tool string
---@param root string
---@param mutants DyMutant[]
function M.show(tool, root, mutants)
  M.clear()
  local counts = { survived = 0, nocoverage = 0, timeout = 0, killed = 0 }
  local items = {}
  local item = require('tools.deadcode').item
  for _, mutant in ipairs(mutants) do
    counts[mutant.status] = (counts[mutant.status] or 0) + 1
    local shown = SHOWN[mutant.status]
    if shown then
      local entry = item(
        root,
        tool,
        mutant.file,
        mutant.lnum,
        mutant.col,
        ('%s: %s'):format(shown[1], mutant.text)
      )
      entry.type = shown[2]
      entry.end_lnum = mutant.end_lnum
      entry.end_col = mutant.end_col
      table.insert(items, entry)
    end
  end
  table.sort(items, function(a, b)
    if (a.filename or '') ~= (b.filename or '') then
      return (a.filename or '') < (b.filename or '')
    end
    return a.lnum < b.lnum
  end)

  if #mutants == 0 then
    return notify(
      ('The %s report holds no mutant'):format(tool),
      vim.log.levels.WARN
    )
  end
  local summary = ('%d survived, %d no test reaches, %d timed out, %d killed, of %d'):format(
    counts.survived,
    counts.nocoverage,
    counts.timeout,
    counts.killed,
    #mutants
  )
  if #items == 0 then
    return notify(('No mutant survived (%s): %s'):format(tool, summary))
  end
  vim.fn.setqflist({}, ' ', { title = M.TITLE, items = items })
  local by_buf = {}
  for _, diagnostic in ipairs(vim.diagnostic.fromqflist(vim.fn.getqflist())) do
    by_buf[diagnostic.bufnr] = by_buf[diagnostic.bufnr] or {}
    diagnostic.source = tool
    table.insert(by_buf[diagnostic.bufnr], diagnostic)
  end
  for buf, diagnostics in pairs(by_buf) do
    vim.diagnostic.set(M.NS, buf, diagnostics)
  end
  vim.cmd('botright copen')
  notify(
    ('%s: %s'):format(tool, summary),
    counts.survived > 0 and vim.log.levels.WARN or vim.log.levels.INFO
  )
end

--- Read the last report of the project of the buffer again, without a run
function M.load()
  local tool, root = M.detect(0)
  if not tool or not root then
    return notify(
      'No Python, JavaScript, TypeScript, Go or Rust project here',
      vim.log.levels.WARN
    )
  end
  local mutants, err = tool.read(root)
  if not mutants then
    return notify(('%s: %s'):format(tool.name, err), vim.log.levels.ERROR)
  end
  M.show(tool.name, root, mutants)
end

--- Run the mutation tool of the project of the buffer in a terminal, on the
--- whole project or, with `file`, on the buffer's file alone, and show its
--- report once it exits
---@param file? boolean
function M.run(file)
  local tool, root = M.detect(0)
  if not tool or not root then
    return notify(
      'No Python, JavaScript, TypeScript, Go or Rust project here',
      vim.log.levels.WARN
    )
  end
  local rel
  if file then
    local name = vim.api.nvim_buf_get_name(0)
    name = vim.uv.fs_realpath(name) or name
    if
      not vim.tbl_contains(tool.filetypes, vim.bo.filetype)
      or not require('util.root').contains(root, name)
    then
      return notify(
        ('The buffer is not a source file of the %s project at %s'):format(
          tool.name,
          vim.fn.fnamemodify(root, ':~')
        ),
        vim.log.levels.ERROR
      )
    end
    rel = name:sub(#root + 2)
  end

  local cmd = tool.cmd(root, rel)
  if vim.fn.executable(cmd[1]) == 0 then
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

  local question = ('Run %s in %s?\nIt runs the tests of the project, once per mutant, as you.'):format(
    tool.name,
    vim.fn.fnamemodify(root, ':~')
  )
  if not require('util.trust').ask('mutate', root, question) then
    return notify(
      ('%s not run: the project is not trusted'):format(tool.name),
      vim.log.levels.WARN
    )
  end

  M.last = { tool = tool, root = root }
  vim.cmd('botright ' .. M.HEIGHT .. 'split')
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.fn.jobstart(cmd, {
    term = true,
    cwd = root,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.tbl_contains(tool.ok, code) then
          return notify(
            ('%s exited %d: see its terminal; no report loaded'):format(
              tool.name,
              code
            ),
            vim.log.levels.ERROR
          )
        end
        if tool.after then tool.after(root, rel) end
        local mutants, err = tool.read(root)
        if not mutants then
          return notify(
            ('%s wrote no readable report: %s'):format(tool.name, err),
            vim.log.levels.ERROR
          )
        end
        M.show(tool.name, root, mutants)
      end)
    end,
  })
  vim.cmd.startinsert()
end

return M
