--- The tests affected by the current change, and only those, run
---
--- The change is every file that differs from the merge base of `HEAD` with
--- the default branch (`origin/HEAD`, else `main`, else `master`) or with a
--- ref given, plus what is not committed yet and untracked files. Each
--- language of the project maps it to tests its own way: jest lists the
--- tests related to the files itself; for Vitest (whose `list` has no
--- related mode) and without jest, the test files whose relative imports
--- reach a changed module; for Go the packages of the changed files and
--- every package importing them, or whose tests do; for Python the test
--- files whose imports reach a changed module, or pytest-testmon when the
--- project keeps its data; for Rust the crates of the workspace holding a
--- changed file and every crate depending on them. A changed test file is
--- always affected. neotest runs them when it has an adapter for the
--- language, else the tool's own command runs in a terminal split.
local M = {}

local notify = require('util.notify').titled('Test Affected')
local system = require('util.system')

--- Milliseconds git or a tool listing tests may take
M.TIMEOUT = 120 * 1000

--- Output kept of git or a tool listing tests
M.MAX_BYTES = 16 * 1024 * 1024

--- Targets named in the notification, the rest counted
M.SHOWN = 10

--- Lines of the terminal split
M.HEIGHT = 12

--- Tried in order when no ref is given
M.DEFAULT_BRANCHES = { 'origin/HEAD', 'main', 'master' }

---@class DyAffectedTarget
---@field path string Relative to the project, `.` for the project itself
---@field why string

---@class DyAffected
---@field tool string What chose them, for the notification
---@field language string Its key in `config.languages`, for the adapter
---@field targets DyAffectedTarget[]
---@field cmd? string[] What runs them in a terminal, without neotest
---@field terminal? boolean Run in a terminal even with neotest

--- Run `args` of git in `root`
---@param root string
---@param args string[]
---@param on_done fun(result: DyRunResult)
local function git(root, args, on_done)
  system.run(
    vim.list_extend({ 'git' }, args),
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    on_done
  )
end

--- The failure of `result`, or nil when it went through; `ok` lists the
--- exit codes besides 0 that are not one
---@param result DyRunResult
---@param name string
---@param ok? integer[]
---@return string?
local function failed(result, name, ok)
  if result.cut then
    return ('%s printed more than %d bytes'):format(name, M.MAX_BYTES)
  end
  if result.code == 0 or vim.tbl_contains(ok or {}, result.code) then
    return nil
  end
  return ('%s: %s'):format(name, system.failure(result, name))
end

--- The fields of NUL-separated `text`
---@param text string
---@return string[]
local function nul_split(text)
  return vim.split(text, '\0', { plain = true, trimempty = true })
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

--- `path` relative to `root`, `.` for `root` itself
---@param root string
---@param path string
---@return string
local function relative(root, path)
  if path == root then return '.' end
  return path:sub(#root + 2)
end

-- The change ------------------------------------------------------------------

--- The merge base of `HEAD` with `ref`, else with the first default branch
--- there is
---@param root string
---@param ref? string
---@param on_done fun(base?: string, err?: string)
function M.base(root, ref, on_done)
  local candidates = ref and { ref } or M.DEFAULT_BRANCHES
  local i, last = 0, nil
  local function try()
    i = i + 1
    local target = candidates[i]
    if not target then
      return on_done(
        nil,
        ref and last
          or ('No default branch (%s): give a ref. %s'):format(
            table.concat(M.DEFAULT_BRANCHES, ', '),
            last or ''
          )
      )
    end
    git(root, { 'merge-base', 'HEAD', target }, function(result)
      last = failed(result, 'git merge-base HEAD ' .. target)
      if last then return try() end
      on_done(vim.trim(result.stdout))
    end)
  end
  try()
end

--- The files of the change under `root`, relative to it: those differing
--- from the merge base, committed or not, and the untracked ones
---@param root string
---@param ref? string
---@param on_done fun(files?: string[], err?: string, base?: string)
function M.changed(root, ref, on_done)
  if ref and ref:sub(1, 1) == '-' then
    return on_done(nil, ('Not a ref: %s'):format(ref))
  end
  M.base(root, ref, function(base, err)
    if not base then return on_done(nil, err) end
    -- `--relative`: paths from `root`, and none outside it
    git(
      root,
      { 'diff', '--name-only', '-z', '--relative', base, '--' },
      function(diff)
        err = failed(diff, 'git diff')
        if err then return on_done(nil, err) end
        git(
          root,
          { 'ls-files', '-z', '--others', '--exclude-standard' },
          function(others)
            err = failed(others, 'git ls-files')
            if err then return on_done(nil, err) end
            local seen, files = {}, {}
            for _, text in ipairs({ diff.stdout, others.stdout }) do
              for _, file in ipairs(nul_split(text)) do
                if not seen[file] then
                  seen[file] = true
                  table.insert(files, file)
                end
              end
            end
            table.sort(files)
            on_done(files, nil, base)
          end
        )
      end
    )
  end)
end

-- Reaching through imports ----------------------------------------------------

--- The test files `changed` reaches through `importers`, each with why
---
--- `importers` maps a key (a module name, a path without extension) to the
--- files importing it; `keys_of` gives the keys a file answers to. A
--- changed test file is affected by itself; one that is gone is left out.
---@param root string
---@param importers table<string, string[]>
---@param changed string[]
---@param keys_of fun(rel: string): string[]
---@param is_test fun(rel: string): boolean
---@return DyAffectedTarget[]
function M.reach(root, importers, changed, keys_of, is_test)
  local origin, queue = {}, {}
  for _, rel in ipairs(changed) do
    if not origin[rel] then
      origin[rel] = rel
      table.insert(queue, rel)
    end
  end
  local i = 1
  while i <= #queue do
    local rel = queue[i]
    i = i + 1
    for _, key in ipairs(keys_of(rel)) do
      for _, file in ipairs(importers[key] or {}) do
        if not origin[file] then
          origin[file] = origin[rel]
          table.insert(queue, file)
        end
      end
    end
  end
  local targets = {}
  for _, rel in ipairs(queue) do
    if is_test(rel) and vim.uv.fs_stat(vim.fs.joinpath(root, rel)) then
      table.insert(targets, {
        path = rel,
        why = origin[rel] == rel and 'changed'
          or ('imports %s'):format(origin[rel]),
      })
    end
  end
  table.sort(targets, function(a, b) return a.path < b.path end)
  return targets
end

--- Add `file` as an importer of `name` and of every package above it
---@param importers table<string, string[]>
---@param name string Dotted
---@param file string
local function add_dotted(importers, name, file)
  local prefix
  for part in name:gmatch('[^.]+') do
    prefix = prefix and prefix .. '.' .. part or part
    importers[prefix] = importers[prefix] or {}
    if importers[prefix][#importers[prefix]] ~= file then
      table.insert(importers[prefix], file)
    end
  end
end

--- Add `file` as an importer of `key`
---@param importers table<string, string[]>
---@param key string
---@param file string
local function add(importers, key, file)
  importers[key] = importers[key] or {}
  if importers[key][#importers[key]] ~= file then
    table.insert(importers[key], file)
  end
end

--- The lines of `git grep -z` output, as file and text
---@param stdout string
---@return fun(): string?, string?
local function grep_lines(stdout)
  local lines = vim.split(stdout, '\n', { plain = true, trimempty = true })
  local i = 0
  return function()
    i = i + 1
    local line = lines[i]
    if not line then return nil end
    local file, text = line:match('^([^%z]+)%z(.*)$')
    return file or '', text or ''
  end
end

-- Python ----------------------------------------------------------------------

--- The module of `rel`, as Python imports it: `src/` and `__init__` dropped
---@param rel string
---@return string
function M.python_module(rel) return require('tools.mutate').python_module(rel) end

--- The modules a line of `rel` imports, dotted and absolute: `from a import
--- b` gives `a` and `a.b`, since `b` may be a module
---@param rel string
---@param line string
---@return string[]
function M.python_imports(rel, line)
  line = line:gsub('#.*$', '')
  local names = {}
  local function each(list, fn)
    for item in (list:gsub('[()\\]', '')):gmatch('[^,]+') do
      item = vim.trim((item:gsub('%s+as%s+.*$', '')))
      if item ~= '' and item ~= '*' then fn(item) end
    end
  end
  local from, list = line:match('^%s*from%s+([%w_.]+)%s+import%s+(.*)$')
  if from then
    local dots, rest = from:match('^(%.*)(.*)$')
    local base = rest
    if #dots > 0 then
      local module = M.python_module(rel)
      local parent = rel:match('__init__%.py$') and module
        or module:match('^(.*)%.[^.]+$')
        or ''
      local parts = vim.split(parent, '.', { plain = true, trimempty = true })
      for _ = 2, #dots do
        table.remove(parts)
      end
      if rest ~= '' then table.insert(parts, rest) end
      base = table.concat(parts, '.')
    end
    if base ~= '' then table.insert(names, base) end
    each(
      list,
      function(name)
        table.insert(names, base == '' and name or base .. '.' .. name)
      end
    )
    return names
  end
  list = line:match('^%s*import%s+(.*)$')
  if list then each(list, function(name) table.insert(names, name) end) end
  return names
end

--- Whether `rel` is a pytest test file
---@param rel string
---@return boolean
local function python_test(rel)
  local name = vim.fs.basename(rel)
  return name:match('^test_.*%.py$') ~= nil or name:match('_test%.py$') ~= nil
end

--- The tests of the Python files `changed` reach, from the import lines
--- `git grep` printed
---@param root string
---@param grep string The output of `git grep -z`
---@param changed string[]
---@return DyAffectedTarget[]
function M.python_targets(root, grep, changed)
  local importers = {}
  for file, text in grep_lines(grep) do
    for _, name in ipairs(M.python_imports(file, text)) do
      add_dotted(importers, name, file)
    end
  end
  local targets = M.reach(
    root,
    importers,
    changed,
    function(rel) return { M.python_module(rel) } end,
    python_test
  )
  -- A fixture file changes the tests beside and below it
  for _, rel in ipairs(changed) do
    if vim.fs.basename(rel) == 'conftest.py' then
      table.insert(
        targets,
        { path = vim.fs.dirname(rel), why = 'changed ' .. rel }
      )
    end
  end
  return targets
end

---@param root string
---@param changed string[]
---@param on_done fun(result?: DyAffected, err?: string)
local function python(root, changed, on_done)
  local pytest =
    local_bin(root, { '.venv/bin/pytest', 'venv/bin/pytest' }, 'pytest')
  if vim.uv.fs_stat(vim.fs.joinpath(root, '.testmondata')) then
    return on_done({
      tool = 'pytest-testmon',
      language = 'python',
      targets = { { path = '.', why = 'pytest-testmon picks them' } },
      cmd = { pytest, '--testmon' },
      terminal = true,
    })
  end
  git(root, {
    'grep',
    '--untracked',
    '-I',
    '-z',
    '-E',
    '^[[:space:]]*(import|from)[[:space:]]',
    '--',
    '*.py',
  }, function(result)
    local err = failed(result, 'git grep', { 1 })
    if err then return on_done(nil, err) end
    local targets = M.python_targets(root, result.stdout, changed)
    local cmd = { pytest }
    for _, target in ipairs(targets) do
      table.insert(cmd, target.path)
    end
    on_done({
      tool = 'imports',
      language = 'python',
      targets = targets,
      cmd = cmd,
    })
  end)
end

-- JavaScript and TypeScript ---------------------------------------------------

--- The extensions of the files this maps
local JS_EXTS = {
  js = true,
  jsx = true,
  mjs = true,
  cjs = true,
  ts = true,
  tsx = true,
  mts = true,
  cts = true,
}

--- Whether `rel` is a jest or Vitest test file
---@param rel string
---@return boolean
local function js_test(rel)
  return rel:match('%.test%.[mc]?[jt]sx?$') ~= nil
    or rel:match('%.spec%.[mc]?[jt]sx?$') ~= nil
    or ('/' .. rel):match('/__tests__/') ~= nil
end

--- `path` with `.` and `..` resolved, relative paths only
---@param path string
---@return string
local function resolve(path)
  local parts = {}
  for part in path:gmatch('[^/]+') do
    if part == '..' then
      table.remove(parts)
    elseif part ~= '.' then
      table.insert(parts, part)
    end
  end
  return table.concat(parts, '/')
end

--- The key of a JavaScript module: its path without the extension
---@param rel string
---@return string
local function js_key(rel)
  local ext = rel:match('%.([%w]+)$')
  return JS_EXTS[ext] and rel:sub(1, -#ext - 2) or rel
end

--- The keys a JavaScript file answers to: its path without the extension,
--- and its directory too when it is an `index`
---@param rel string
---@return string[]
local function js_keys(rel)
  local key = js_key(rel)
  local keys = { key }
  if vim.fs.basename(key) == 'index' then
    table.insert(keys, vim.fs.dirname(key))
  end
  return keys
end

--- The tests of the JavaScript files `changed` reach through relative
--- imports, from the lines `git grep` printed
---
--- shortcut: path aliases (`@/x`, `paths` of `tsconfig.json`) and
--- packages of a workspace are not followed; jest follows them itself.
---@param root string
---@param grep string The output of `git grep -z`
---@param changed string[]
---@return DyAffectedTarget[]
function M.js_targets(root, grep, changed)
  local importers = {}
  for file, text in grep_lines(grep) do
    local dir = vim.fs.dirname(file)
    for spec in text:gmatch('[\'"](%.%.?/[^\'"]*)[\'"]') do
      add(importers, js_key(resolve(dir .. '/' .. spec)), file)
    end
  end
  return M.reach(root, importers, changed, js_keys, js_test)
end

---@param root string
---@param changed string[]
---@param on_done fun(result?: DyAffected, err?: string)
local function javascript(root, changed, on_done)
  local jest = local_bin(root, { 'node_modules/.bin/jest' }, '')
  local vitest = local_bin(root, { 'node_modules/.bin/vitest' }, '')
  ---@param tool string
  ---@param targets DyAffectedTarget[]
  local function done(tool, targets)
    local cmd = jest ~= '' and { jest }
      or vitest ~= '' and { vitest, 'run' }
      or nil
    if cmd then
      for _, target in ipairs(targets) do
        table.insert(cmd, target.path)
      end
    end
    on_done({
      tool = tool,
      language = 'typescript',
      targets = targets,
      cmd = cmd,
    })
  end
  if jest ~= '' then
    local cmd = { jest, '--listTests', '--findRelatedTests' }
    for _, rel in ipairs(changed) do
      -- jest stops on a path that is not there
      if vim.uv.fs_stat(vim.fs.joinpath(root, rel)) then
        table.insert(cmd, rel)
      end
    end
    if #cmd == 3 then return done('jest', {}) end
    return system.run(
      cmd,
      { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
      function(result)
        local err = failed(result, 'jest --listTests')
        if err then return on_done(nil, err) end
        local targets = {}
        for line in result.stdout:gmatch('[^\n]+') do
          if vim.startswith(line, '/') then
            local path = vim.uv.fs_realpath(line) or line
            if require('util.root').contains(root, path) then
              table.insert(
                targets,
                { path = relative(root, path), why = 'jest: related' }
              )
            end
          end
        end
        table.sort(targets, function(a, b) return a.path < b.path end)
        done('jest', targets)
      end
    )
  end
  local globs = {}
  for ext in pairs(JS_EXTS) do
    table.insert(globs, '*.' .. ext)
  end
  table.sort(globs)
  git(
    root,
    vim.list_extend({
      'grep',
      '--untracked',
      '-I',
      '-z',
      '-E',
      '[\'"]\\.\\.?/',
      '--',
    }, globs),
    function(result)
      local err = failed(result, 'git grep', { 1 })
      if err then return on_done(nil, err) end
      done('imports', M.js_targets(root, result.stdout, changed))
    end
  )
end

-- Go --------------------------------------------------------------------------

--- What `go list` prints of each package: its directory, import path,
--- imports, the imports of its tests, and whether it has tests
M.GO_FORMAT = table.concat({
  '{{.Dir}}',
  '{{.ImportPath}}',
  '{{join .Imports " "}}',
  '{{join .TestImports " "}} {{join .XTestImports " "}}',
  '{{if or .TestGoFiles .XTestGoFiles}}t{{end}}',
}, '\t')

--- The packages with tests the Go files `changed` affect: theirs, those
--- importing them, directly or not, and those whose tests import one of
--- them, from `go list -f M.GO_FORMAT`
---@param root string
---@param stdout string
---@param changed string[]
---@return DyAffectedTarget[]
function M.go_targets(root, stdout, changed)
  local by_dir, packages, importers = {}, {}, {}
  for line in stdout:gmatch('[^\n]+') do
    local fields = vim.split(line, '\t', { plain = true })
    local pkg = {
      -- go takes $PWD over the real directory it runs in
      dir = vim.uv.fs_realpath(fields[1]) or fields[1],
      path = fields[2],
      imports = vim.split(fields[3] or '', ' ', { trimempty = true }),
      test_imports = vim.split(fields[4] or '', ' ', { trimempty = true }),
      tests = fields[5] == 't',
    }
    if pkg.path and pkg.path ~= '' then
      by_dir[pkg.dir] = pkg
      table.insert(packages, pkg)
      for _, import in ipairs(pkg.imports) do
        importers[import] = importers[import] or {}
        table.insert(importers[import], pkg)
      end
    end
  end
  local why, queue = {}, {}
  for _, rel in ipairs(changed) do
    local dir = vim.fs.dirname(rel)
    local pkg = by_dir[dir == '.' and root or vim.fs.joinpath(root, dir)]
    if pkg and not why[pkg.path] then
      why[pkg.path] = 'changed'
      table.insert(queue, pkg)
    end
  end
  local i = 1
  while i <= #queue do
    local pkg = queue[i]
    i = i + 1
    for _, importer in ipairs(importers[pkg.path] or {}) do
      if not why[importer.path] then
        why[importer.path] = 'imports ' .. pkg.path
        table.insert(queue, importer)
      end
    end
  end
  local targets = {}
  for _, pkg in ipairs(packages) do
    if not why[pkg.path] then
      for _, import in ipairs(pkg.test_imports) do
        if why[import] then
          why[pkg.path] = 'its tests import ' .. import
          break
        end
      end
    end
    if why[pkg.path] and pkg.tests then
      table.insert(
        targets,
        { path = relative(root, pkg.dir), why = why[pkg.path] }
      )
    end
  end
  table.sort(targets, function(a, b) return a.path < b.path end)
  return targets
end

---@param root string
---@param changed string[]
---@param on_done fun(result?: DyAffected, err?: string)
local function go(root, changed, on_done)
  -- shortcut: one module, the one at the root; a `go.work` of several is
  -- read as that one alone
  system.run(
    { 'go', 'list', '-e', '-f', M.GO_FORMAT, './...' },
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      local err = failed(result, 'go list')
      if err then return on_done(nil, err) end
      local targets = M.go_targets(root, result.stdout, changed)
      local cmd = { 'go', 'test' }
      for _, target in ipairs(targets) do
        table.insert(cmd, target.path == '.' and '.' or './' .. target.path)
      end
      on_done({
        tool = 'go list',
        language = 'go',
        targets = targets,
        cmd = cmd,
      })
    end
  )
end

-- Rust ------------------------------------------------------------------------

--- The crates of the workspace the Rust files `changed` affect: those
--- holding one, and those depending on them, directly or not, from
--- `cargo metadata --no-deps`
---@param root string
---@param metadata table
---@param changed string[]
---@return DyAffectedTarget[]
---@return string[] names The crates, for `cargo test -p`
function M.rust_targets(root, metadata, changed)
  local crates, dependents = {}, {}
  for _, pkg in ipairs(metadata.packages or {}) do
    local dir = vim.fs.dirname(pkg.manifest_path)
    local crate = { name = pkg.name, dir = vim.uv.fs_realpath(dir) or dir }
    table.insert(crates, crate)
    for _, dep in ipairs(pkg.dependencies or {}) do
      dependents[dep.name] = dependents[dep.name] or {}
      table.insert(dependents[dep.name], crate)
    end
  end
  -- The deepest crate holding a file owns it
  table.sort(crates, function(a, b) return #a.dir > #b.dir end)
  local contains = require('util.root').contains
  local why, queue = {}, {}
  for _, rel in ipairs(changed) do
    local path = vim.fs.joinpath(root, rel)
    for _, crate in ipairs(crates) do
      if contains(crate.dir, path) then
        if not why[crate.name] then
          why[crate.name] = 'changed'
          table.insert(queue, crate)
        end
        break
      end
    end
  end
  local i = 1
  while i <= #queue do
    local crate = queue[i]
    i = i + 1
    for _, dependent in ipairs(dependents[crate.name] or {}) do
      if not why[dependent.name] then
        why[dependent.name] = 'depends on ' .. crate.name
        table.insert(queue, dependent)
      end
    end
  end
  table.sort(queue, function(a, b) return a.dir < b.dir end)
  local targets, names = {}, {}
  for _, crate in ipairs(queue) do
    table.insert(
      targets,
      { path = relative(root, crate.dir), why = why[crate.name] }
    )
    table.insert(names, crate.name)
  end
  return targets, names
end

---@param root string
---@param changed string[]
---@param on_done fun(result?: DyAffected, err?: string)
local function rust(root, changed, on_done)
  system.run(
    { 'cargo', 'metadata', '--no-deps', '--format-version', '1' },
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      local err = failed(result, 'cargo metadata')
      if err then return on_done(nil, err) end
      local ok, metadata = pcall(vim.json.decode, result.stdout)
      if not ok or type(metadata) ~= 'table' then
        return on_done(nil, 'cargo metadata printed no JSON')
      end
      local targets, names = M.rust_targets(root, metadata, changed)
      local cmd = { 'cargo', 'test' }
      for _, name in ipairs(names) do
        vim.list_extend(cmd, { '-p', name })
      end
      on_done({
        tool = 'cargo metadata',
        language = 'rust',
        targets = targets,
        cmd = cmd,
      })
    end
  )
end

-- The languages ---------------------------------------------------------------

---@class DyAffectedLanguage
---@field name string
---@field markers string[] Files at the root of a project of it
---@field owns fun(rel: string): boolean Whether a changed file is its
---@field map fun(root: string, changed: string[], on_done: fun(result?: DyAffected, err?: string))

--- The languages, in the order they are told
---@type DyAffectedLanguage[]
M.LANGUAGES = {
  {
    name = 'Go',
    markers = { 'go.mod' },
    owns = function(rel) return rel:match('%.go$') ~= nil end,
    map = go,
  },
  {
    name = 'JavaScript',
    markers = { 'package.json' },
    owns = function(rel) return JS_EXTS[rel:match('%.(%w+)$') or ''] ~= nil end,
    map = javascript,
  },
  {
    name = 'Python',
    markers = { 'pyproject.toml', 'setup.py', 'setup.cfg', 'pytest.ini' },
    owns = function(rel) return rel:match('%.py$') ~= nil end,
    map = python,
  },
  {
    name = 'Rust',
    markers = { 'Cargo.toml' },
    owns = function(rel)
      return rel:match('%.rs$') ~= nil or vim.fs.basename(rel) == 'Cargo.toml'
    end,
    map = rust,
  },
}

-- Running ---------------------------------------------------------------------

--- Whether neotest runs the tests of `language`: it is installed and the
--- language names an adapter
---@param language string
---@return boolean
function M.has_adapter(language)
  if not require('util.plugin').has('neotest') then return false end
  local spec = require('config.languages')[language]
  return spec ~= nil and type(spec.test) == 'table' and #spec.test > 0
end

--- Run `cmd` in a terminal split in `root`
---@param root string
---@param cmd string[]
local function terminal(root, cmd)
  vim.cmd('botright ' .. M.HEIGHT .. 'split')
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.fn.jobstart(cmd, { term = true, cwd = root })
  vim.cmd.startinsert()
end

--- Run the targets of `result`; how, or nil and why not
---@param root string
---@param result DyAffected
---@return string?
---@return string?
function M.launch(root, result)
  if not result.terminal and M.has_adapter(result.language) then
    local neotest = require('neotest')
    for _, target in ipairs(result.targets) do
      neotest.run.run(
        target.path == '.' and root or vim.fs.joinpath(root, target.path)
      )
    end
    return 'neotest'
  end
  if not result.cmd then
    return nil,
      ('%s: no neotest adapter, nor jest or vitest in node_modules'):format(
        result.tool
      )
  end
  if vim.fn.executable(result.cmd[1]) ~= 1 then
    return nil, ('%s is not installed'):format(result.cmd[1])
  end
  terminal(root, result.cmd)
  return 'a terminal'
end

--- The notification of what ran, and why
---@param lines string[]
---@param result DyAffected
---@param how string
local function describe(lines, result, how)
  table.insert(
    lines,
    ('%d by %s, run in %s:'):format(#result.targets, result.tool, how)
  )
  for i, target in ipairs(result.targets) do
    if i > M.SHOWN then
      table.insert(lines, ('  and %d more'):format(#result.targets - M.SHOWN))
      break
    end
    table.insert(lines, ('  %s (%s)'):format(target.path, target.why))
  end
end

--- Map `files` to tests and run them, and tell which and why
---@param root string
---@param files string[]
---@param base string
function M.run_files(root, files, base)
  local short = base:sub(1, 8)
  if #files == 0 then
    return notify(('Nothing changed since %s'):format(short))
  end
  local jobs = {}
  for _, language in ipairs(M.LANGUAGES) do
    local has_marker = vim.iter(language.markers):any(
      function(marker)
        return vim.uv.fs_stat(vim.fs.joinpath(root, marker)) ~= nil
      end
    )
    local owned = vim.tbl_filter(language.owns, files)
    if has_marker and #owned > 0 then
      table.insert(jobs, { language = language, files = owned })
    end
  end
  if #jobs == 0 then
    return notify(
      ('No test is affected: none of the %d changed files since %s is Go, JavaScript, TypeScript, Python or Rust of a project at %s'):format(
        #files,
        short,
        vim.fn.fnamemodify(root, ':~')
      ),
      vim.log.levels.WARN
    )
  end
  local results, errors = {}, {}
  system.each(jobs, 4, function(job, done)
    job.language.map(root, job.files, function(result, err)
      if result then
        results[job.language.name] = result
      else
        errors[job.language.name] = err or 'failed'
      end
      done()
    end)
  end, function()
    local lines, problems = {}, {}
    for _, job in ipairs(jobs) do
      local name = job.language.name
      local result = results[name]
      if errors[name] then
        table.insert(
          problems,
          ('%s: tests not mapped: %s'):format(name, errors[name])
        )
      elseif result and #result.targets > 0 then
        local how, err = M.launch(root, result)
        if how then
          describe(lines, result, how)
        else
          table.insert(problems, ('%s: not run: %s'):format(name, err))
        end
      end
    end
    if #problems > 0 then
      notify(table.concat(problems, '\n'), vim.log.levels.ERROR)
    end
    if #lines > 0 then
      table.insert(
        lines,
        1,
        ('Tests affected by %d changed files since %s'):format(#files, short)
      )
      notify(table.concat(lines, '\n'))
    elseif #problems == 0 then
      notify(
        ('No test is affected by the %d changed files since %s'):format(
          #files,
          short
        )
      )
    end
  end)
end

--- Run the tests affected by the change of the project since the merge base
--- with the default branch, or with `ref`
---@param ref? string
function M.run(ref)
  local root = require('util.root')()
  root = vim.uv.fs_realpath(root) or root
  local question = ('Run the tests affected by the change in %s?\nListing and running them runs code of the project, as you.'):format(
    vim.fn.fnamemodify(root, ':~')
  )
  if not require('util.trust').ask('testaffected', root, question) then
    return notify(
      'Tests not run: the project is not trusted',
      vim.log.levels.WARN
    )
  end
  M.changed(root, ref, function(files, err, base)
    if not files or not base then
      return notify(
        ('Cannot tell what changed: %s'):format(err),
        vim.log.levels.ERROR
      )
    end
    M.run_files(root, files, base)
  end)
end

return M
