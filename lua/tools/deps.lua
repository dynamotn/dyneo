--- The dependency rules of a project, checked
---
--- An architecture says which module may use which; a project writes that
--- down for a tool that checks it. `:DyDeps` finds the one the project of
--- the buffer is set up for -- dependency-cruiser for JavaScript and
--- TypeScript, go-arch-lint for Go, import-linter for Python -- runs it off
--- the main loop and puts every broken rule in the quickfix list. A run
--- whose output cannot be read is a failure, never a clean result; one that
--- exits non-zero with nothing read is one too, since go-arch-lint and
--- import-linter exit non-zero only when a rule breaks.
local M = {}

local notify = require('util.notify').titled('Dependencies')

--- Milliseconds a check may take: they walk the whole project
M.TIMEOUT = 120 * 1000

local SEVERITY = { error = 'E', warn = 'W', info = 'I' }

--- Decode `text` as JSON, or nil
---@param text string
---@return table?
local function json(text)
  local ok, value =
    pcall(vim.json.decode, text, { luanil = { object = true, array = true } })
  return ok and type(value) == 'table' and value or nil
end

--- The quickfix items of `depcruise --output-type baseline`: the violations
--- alone, where `json` lists every module of the project as well and soon
--- outgrows what can be read. They name modules, not lines, so each points
--- at the top of the module that breaks a rule.
---@param text string
---@param root string
---@return vim.quickfix.entry[]?
function M.depcruise(text, root)
  local violations = json(text)
  if not violations or not vim.islist(violations) then return nil end
  violations = vim.tbl_filter(
    function(violation)
      return type(violation) == 'table'
        and vim.tbl_get(violation, 'rule', 'severity') ~= 'ignore'
    end,
    violations
  )
  return vim.tbl_map(function(violation)
    local rule = violation.rule or {}
    local text_of = ('%s: %s → %s'):format(
      rule.name or 'rule',
      violation.from or '?',
      violation.to or '?'
    )
    if type(violation.cycle) == 'table' and #violation.cycle > 0 then
      local steps = vim.tbl_map(
        function(step) return type(step) == 'table' and step.name or step end,
        violation.cycle
      )
      text_of = text_of .. ' (cycle: ' .. table.concat(steps, ' → ') .. ')'
    end
    return {
      filename = vim.fs.joinpath(root, violation.from or ''),
      lnum = 1,
      type = SEVERITY[rule.severity] or 'W',
      text = text_of,
    }
  end, violations)
end

--- The file and position of a go-arch-lint reference, or nil when it is
--- not `Valid` (its `File` is then an empty string)
---@param ref table?
---@param root string
---@return string? file
---@return integer lnum
---@return integer col
local function reference(ref, root)
  if type(ref) ~= 'table' or not ref.Valid or (ref.File or '') == '' then
    return nil, 1, 0
  end
  local file = ref.File
  if not vim.startswith(file, '/') then file = vim.fs.joinpath(root, file) end
  return file, ref.Line or 1, ref.Offset or 0
end

--- The quickfix items of `go-arch-lint check --json`, and how many more it
--- left out
---@param text string
---@param root string
---@return vim.quickfix.entry[]? items
---@return string? note
function M.go_arch_lint(text, root)
  local payload = (json(text) or {}).Payload
  if type(payload) ~= 'table' then return nil end
  local items = {}
  for _, warning in ipairs(payload.ArchWarningsDeps or {}) do
    local file, lnum, col = reference(warning.Reference, root)
    table.insert(items, {
      filename = file
        or warning.FileAbsolutePath
        or vim.fs.joinpath(root, warning.FileRelativePath or ''),
      lnum = lnum,
      col = col,
      type = 'E',
      text = ('%s may not depend on %s'):format(
        warning.ComponentName or '?',
        warning.ResolvedImportName or '?'
      ),
    })
  end
  for _, warning in ipairs(payload.ArchWarningsNotMatched or {}) do
    table.insert(items, {
      filename = warning.FileAbsolutePath
        or vim.fs.joinpath(root, warning.FileRelativePath or ''),
      lnum = 1,
      type = 'W',
      text = 'In no component of .go-arch-lint.yml',
    })
  end
  -- deepScan: a component handed, where it is built, one it may not use
  for _, warning in ipairs(payload.ArchWarningsDeepScan or {}) do
    local dependency, gate = warning.Dependency or {}, warning.Gate or {}
    local file, lnum, col = reference(dependency.Injection, root)
    if not file then
      file, lnum, col = reference(gate.Definition, root)
    end
    table.insert(items, {
      filename = file or root,
      lnum = lnum,
      col = col,
      type = 'E',
      text = ('%s may not be given %s (%s to %s)'):format(
        gate.ComponentName or '?',
        dependency.ComponentName or '?',
        dependency.Name or '?',
        gate.MethodName or '?'
      ),
    })
  end
  local omitted = tonumber(payload.OmittedCount) or 0
  return items, omitted > 0 and ('%d more not shown'):format(omitted) or nil
end

--- The file of Python module `name` under `root`, or nil
---@param root string
---@param name string
---@return string?
local function module_file(root, name)
  local path = name:gsub('%.', '/')
  for _, base in ipairs({ root, vim.fs.joinpath(root, 'src') }) do
    for _, candidate in ipairs({ path .. '.py', path .. '/__init__.py' }) do
      local file = vim.fs.joinpath(base, candidate)
      if vim.uv.fs_stat(file) then return file end
    end
  end
  return nil
end

--- The quickfix items of what `lint-imports` printed: each import line
--- `- a.b -> c.d (l.12)` under the rule it breaks
---@param text string
---@param root string
---@return vim.quickfix.entry[]
function M.import_linter(text, root)
  local items, rule = {}, nil
  for line in vim.gsplit(text, '\n', { plain = true }) do
    rule = line:match('^(%S+ is not allowed to import %S+):%s*$')
      or line:match('^(%S+ must not import %S+):%s*$')
      or rule
    local from, to, lnum =
      line:match('^%s*%-%s+([%w_%.]+)%s+%->%s+([%w_%.]+).-%(l%.(%d+)')
    if from then
      table.insert(items, {
        filename = module_file(root, from) or root,
        lnum = tonumber(lnum),
        type = 'E',
        text = ('%s: %s → %s'):format(rule or 'broken contract', from, to),
      })
    end
  end
  return items
end

--- `lint-imports` of the project's `.venv` first: it imports the project,
--- so it needs the packages installed there
---@param root string
---@return string[]
local function lint_imports(root)
  local local_bin = vim.fs.joinpath(root, '.venv/bin/lint-imports')
  return { vim.fn.executable(local_bin) == 1 and local_bin or 'lint-imports' }
end

---@class DyDepsTool
---@field name string
---@field markers string[] Files at the root that say the project uses it
---@field cmd fun(root: string): string[]
---@field parse fun(text: string, root: string): vim.quickfix.entry[]?, string?
---@field contains? string Text a marker must hold, for a shared file

--- The tools, in the order they are looked for
---@type DyDepsTool[]
M.TOOLS = {
  {
    name = 'dependency-cruiser',
    markers = {
      '.dependency-cruiser.js',
      '.dependency-cruiser.cjs',
      '.dependency-cruiser.mjs',
      '.dependency-cruiser.json',
      '.dependency-cruiser.ts',
      '.dependency-cruiser.cts',
      '.dependency-cruiser.mts',
    },
    cmd = function(root)
      local local_bin = vim.fs.joinpath(root, 'node_modules/.bin/depcruise')
      local bin = vim.fn.executable(local_bin) == 1 and local_bin or 'depcruise'
      local src = vim.fn.isdirectory(vim.fs.joinpath(root, 'src')) == 1
          and 'src'
        or '.'
      return { bin, '--output-type', 'baseline', src }
    end,
    parse = M.depcruise,
  },
  {
    name = 'go-arch-lint',
    markers = { '.go-arch-lint.yml', '.go-arch-lint.yaml' },
    cmd = function(root)
      return { 'go-arch-lint', 'check', '--json', '--project-path', root }
    end,
    parse = M.go_arch_lint,
  },
  {
    name = 'import-linter',
    markers = { '.importlinter' },
    cmd = lint_imports,
    parse = M.import_linter,
  },
  {
    name = 'import-linter',
    markers = { 'pyproject.toml' },
    contains = '[tool.importlinter]',
    cmd = lint_imports,
    parse = M.import_linter,
  },
  {
    name = 'import-linter',
    markers = { 'setup.cfg' },
    contains = '[importlinter]',
    cmd = lint_imports,
    parse = M.import_linter,
  },
}

--- Whether the first lines of `file` hold `text`
---@param file string
---@param text string
---@return boolean
local function holds(file, text)
  local ok, lines = pcall(vim.fn.readfile, file, '', 2000)
  return ok and table.concat(lines, '\n'):find(text, 1, true) ~= nil
end

--- The nearest directory above `path` that is set up for `tool`: a shared
--- file without the text of the tool says nothing, and the walk goes on up
---@param tool DyDepsTool
---@param path string
---@return string?
local function root_of(tool, path)
  local hits = vim.fs.find(
    tool.markers,
    { path = path, upward = true, type = 'file', limit = math.huge }
  )
  for _, hit in ipairs(hits) do
    if not tool.contains or holds(hit, tool.contains) then
      return vim.fs.dirname(hit)
    end
  end
  return nil
end

--- The tool the project around `bufnr` is set up for, and its root: the
--- nearest configuration wins, and of two in one directory the one listed
--- first in `M.TOOLS`
---@param bufnr integer
---@return DyDepsTool? tool
---@return string? root
function M.find(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  local path = name == '' and vim.fn.getcwd() or vim.fs.dirname(name)
  local found, found_root
  for _, tool in ipairs(M.TOOLS) do
    local root = root_of(tool, path)
    -- Every root is above the same path, so the longest is the nearest
    if root and (not found_root or #root > #found_root) then
      found, found_root = tool, root
    end
  end
  return found, found_root
end

--- Check the rules of the project of the current buffer
function M.check()
  local tool, root = M.find(0)
  if not tool or not root then
    return notify(
      'No dependency rules here: no dependency-cruiser, go-arch-lint or import-linter configuration',
      vim.log.levels.WARN
    )
  end
  -- Every one of them loads the project's own configuration, binaries or
  -- code, so it runs only where the user said it may
  local question = ('Run %s in %s?\nIt loads the configuration and code of the project as you.'):format(
    tool.name,
    vim.fn.fnamemodify(root, ':~')
  )
  if not require('util.trust').ask('deps', root, question) then
    return notify(('%s not run'):format(tool.name), vim.log.levels.WARN)
  end
  local system = require('util.system')
  notify(('Checking with %s…'):format(tool.name))
  system.run(
    tool.cmd(root),
    { cwd = root, timeout = M.TIMEOUT },
    function(result)
      if result.missing or result.timed_out or result.cut then
        return notify(
          result.cut and (tool.name .. ' said more than can be read')
            or system.failure(result, tool.name),
          vim.log.levels.ERROR
        )
      end
      local items, note = tool.parse(result.stdout or '', root)
      -- A failed run with nothing read is a failure, not a clean result
      if not items or (#items == 0 and result.code ~= 0) then
        return notify(
          ('%s failed: %s'):format(tool.name, system.failure(result, tool.name)),
          vim.log.levels.ERROR
        )
      end
      if #items == 0 then
        return notify(('No rule broken (%s)'):format(tool.name))
      end
      vim.fn.setqflist({}, ' ', {
        title = 'Dependency rules: ' .. tool.name,
        items = items,
      })
      vim.cmd('botright copen')
      notify(
        ('%d rules broken (%s)%s'):format(
          #items,
          tool.name,
          note and ('; ' .. note) or ''
        ),
        vim.log.levels.WARN
      )
    end
  )
end

return M
