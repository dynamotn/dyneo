--- The code nothing uses, across a project
---
--- Each language of the project, told by the files at its root, has the
--- tool that knows it look: knip for the unused files, exports and
--- dependencies of JavaScript and TypeScript, vulture for Python, `deadcode`
--- for the functions of Go no `main` reaches, cargo-machete for the unused
--- dependencies of Rust. They run off the main loop, and what they find goes
--- to one quickfix list. A tool missing or failing says which and why: a run
--- that failed never reads as a project without dead code.
local M = {}

local notify = require('util.notify').titled('Dead Code')

--- Milliseconds a tool may take on the project
M.TIMEOUT = 180 * 1000

--- Output kept of a tool, stdout and stderr together
M.MAX_BYTES = 4 * 1024 * 1024

--- Tools run at once
M.LIMIT = 2

--- The lowest confidence of vulture reported: 60 is what it gives an unused
--- function, class or variable, 90 an unused import, 100 unreachable code
M.MIN_CONFIDENCE = 60

--- What vulture skips, unless the project's `[tool.vulture]` says otherwise
M.VULTURE_EXCLUDE = {
  '*/.venv/*',
  '*/venv/*',
  '*/.tox/*',
  '*/.nox/*',
  '*/site-packages/*',
  '*/node_modules/*',
}

--- The quickfix item of `file` (relative to `root`, or absolute) at `lnum`,
--- or one pointing at no file when it lies outside the project
---@param root string Symlinks resolved
---@param tool string
---@param file string
---@param lnum? integer
---@param col? integer
---@param text string
---@return vim.quickfix.entry
function M.item(root, tool, file, lnum, col, text)
  local path = vim.fs.normalize(
    file:sub(1, 1) == '/' and file or vim.fs.joinpath(root, file)
  )
  local real = vim.uv.fs_realpath(path) or path
  local inside = require('util.root').contains(root, real)
  return {
    filename = inside and path or nil,
    lnum = lnum or 1,
    col = col or 1,
    type = 'W',
    text = ('[%s] %s%s'):format(
      tool,
      text,
      inside and '' or (' (outside the project: %s)'):format(file)
    ),
    valid = inside,
  }
end

--- The items of knip's SARIF report
---@param text string
---@param root string
---@return vim.quickfix.entry[]?
function M.knip(text, root)
  local ok, report = pcall(vim.json.decode, text)
  if not ok or type(report) ~= 'table' then return nil end
  local items = require('tools.sarif').items(report, root)
  for _, item in ipairs(items) do
    -- `[knip knip/exports] Unused export: x`: the rule says it twice
    item.text = item.text:gsub('^%[knip knip/[%w-]+%]', '[knip]')
    item.type = 'W'
  end
  return items
end

--- The items of vulture: `m.py:6: unused function 'f' (60% confidence)`
---@param text string
---@param root string
---@return vim.quickfix.entry[]
function M.vulture(text, root)
  local items = {}
  for line in vim.gsplit(text, '\n', { trimempty = true }) do
    local file, lnum, message = line:match('^(.-):(%d+): (.+)$')
    if file then
      table.insert(
        items,
        M.item(root, 'vulture', file, tonumber(lnum), 1, message)
      )
    end
  end
  return items
end

--- The items of `deadcode`: `main.go:5:6: unreachable func: unused`
---@param text string
---@param root string
---@return vim.quickfix.entry[]
function M.deadcode(text, root)
  local items = {}
  for line in vim.gsplit(text, '\n', { trimempty = true }) do
    local file, lnum, col, message = line:match('^(.-):(%d+):(%d+): (.+)$')
    if file then
      table.insert(
        items,
        M.item(root, 'deadcode', file, tonumber(lnum), tonumber(col), message)
      )
    end
  end
  return items
end

--- The line of `Cargo.toml` that declares `dep`, else 1
---@param file string
---@param dep string
---@return integer
local function declared_at(file, dep)
  local ok, lines = pcall(vim.fn.readfile, file, '', 5000)
  if not ok then return 1 end
  local name = vim.pesc(dep)
  for lnum, line in ipairs(lines) do
    if
      line:match('^%s*' .. name .. '%s*=')
      or line:match('^%s*%[.*dependencies%.' .. name .. '%]')
    then
      return lnum
    end
  end
  return 1
end

--- The items of cargo-machete: a `crate -- ./Cargo.toml:` line, then each
--- unused dependency of that manifest on a line of its own, indented by a tab
---@param text string
---@param root string
---@return vim.quickfix.entry[]
function M.cargo_machete(text, root)
  local items, manifest = {}, nil
  for line in vim.gsplit(text, '\n', { trimempty = true }) do
    local file = line:match('^%S.* %-%- (.+):$')
    local dep = line:match('^\t(%S+)$')
    if file then
      manifest = file
    elseif dep and manifest then
      local item = M.item(
        root,
        'cargo-machete',
        manifest,
        1,
        1,
        'unused dependency: ' .. dep
      )
      if item.filename then item.lnum = declared_at(item.filename, dep) end
      table.insert(items, item)
    elseif not line:match('^\t') then
      manifest = nil
    end
  end
  return items
end

--- Whether `root` holds any of `names`, globs allowed
---@param root string
---@param names string[]
---@return boolean
local function holds(root, names)
  for _, name in ipairs(names) do
    if vim.fn.glob(vim.fs.joinpath(root, name)) ~= '' then return true end
  end
  return false
end

---@class DyDeadCodeTool
---@field name string
---@field bin string The binary
---@field mason string Its Mason package
---@field markers string[] Files at the root of a project it is for
---@field ok integer[] Exit codes of a run that went through
---@field runs_code? boolean Loads the project's configuration, as code
---@field cmd fun(root: string): string[]
---@field parse fun(text: string, root: string): vim.quickfix.entry[]?

--- The tools, in the order they are listed
---@type DyDeadCodeTool[]
M.TOOLS = {
  {
    name = 'knip',
    bin = 'knip',
    mason = 'knip',
    markers = { 'package.json', 'tsconfig.json' },
    ok = { 0 },
    -- Its plugins read `vite.config.ts` and the like by running them
    runs_code = true,
    cmd = function(root)
      local local_bin = vim.fs.joinpath(root, 'node_modules/.bin/knip')
      return {
        vim.fn.executable(local_bin) == 1 and local_bin or 'knip',
        '--reporter',
        'sarif',
        '--no-progress',
        '--no-config-hints',
        '--no-exit-code',
      }
    end,
    parse = function(text, root) return M.knip(text, root) end,
  },
  {
    name = 'vulture',
    bin = 'vulture',
    mason = 'vulture',
    markers = { 'pyproject.toml', 'setup.py', 'requirements*.txt' },
    -- 3 when it found something
    ok = { 0, 3 },
    cmd = function(root)
      local pyproject = vim.fs.joinpath(root, 'pyproject.toml')
      local ok, lines = pcall(vim.fn.readfile, pyproject, '', 2000)
      if ok and vim.tbl_contains(lines, '[tool.vulture]') then
        return { 'vulture', root }
      end
      return {
        'vulture',
        '--min-confidence',
        tostring(M.MIN_CONFIDENCE),
        '--exclude',
        table.concat(M.VULTURE_EXCLUDE, ','),
        root,
      }
    end,
    parse = function(text, root) return M.vulture(text, root) end,
  },
  {
    name = 'deadcode',
    bin = 'deadcode',
    mason = 'deadcode',
    markers = { 'go.mod' },
    ok = { 0 },
    -- Tests count as uses, as they do in an IDE
    cmd = function() return { 'deadcode', '-test', './...' } end,
    parse = function(text, root) return M.deadcode(text, root) end,
  },
  {
    name = 'cargo-machete',
    bin = 'cargo-machete',
    mason = 'cargo-machete',
    markers = { 'Cargo.toml' },
    -- 1 when it found something
    ok = { 0, 1 },
    cmd = function() return { 'cargo-machete', '--skip-target-dir' } end,
    parse = function(text, root) return M.cargo_machete(text, root) end,
  },
}

--- The tools for the project at `root`
---@param root string
---@return DyDeadCodeTool[]
function M.applicable(root)
  return vim.tbl_filter(
    function(tool) return holds(root, tool.markers) end,
    M.TOOLS
  )
end

--- The names of the tools for the project of the buffer, for completion
---@return string[]
function M.complete()
  return vim.tbl_map(
    function(tool) return tool.name end,
    M.applicable(require('util.root')())
  )
end

--- Run `tool` on `root` and hand `done` its items and why it failed, if it
--- did; items found before a failure are kept
---@param tool DyDeadCodeTool
---@param root string
---@param done fun(items: vim.quickfix.entry[], failure?: string)
local function run_one(tool, root, done)
  local system = require('util.system')
  system.run(
    tool.cmd(root),
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      if result.missing then
        require('util.lazy_install').install_once(tool.mason)
        return done(
          {},
          ('%s is not installed: Mason installs it, run again once it is done'):format(
            tool.bin
          )
        )
      end
      if result.timed_out then
        return done({}, system.failure(result, tool.name))
      end
      local items = tool.parse(result.stdout or '', root)
      if not items then
        return done(
          {},
          ('%s wrote nothing readable: %s'):format(
            tool.name,
            system.failure(result, tool.name)
          )
        )
      end
      if result.cut or not vim.tbl_contains(tool.ok, result.code) then
        return done(items, system.failure(result, tool.name))
      end
      done(items)
    end
  )
end

--- List the dead code of the project of the buffer, by every tool that
--- applies to it, or by `name` alone
---@param name? string
function M.run(name)
  local root = require('util.root')()
  root = vim.uv.fs_realpath(root) or root
  local tools = M.applicable(root)
  if name then
    tools = vim.tbl_filter(function(tool) return tool.name == name end, M.TOOLS)
    if #tools == 0 then
      return notify(('No tool called %s'):format(name), vim.log.levels.ERROR)
    end
  end
  if #tools == 0 then
    return notify(
      ('No JavaScript, TypeScript, Python, Go or Rust project at %s'):format(
        vim.fn.fnamemodify(root, ':~')
      ),
      vim.log.levels.WARN
    )
  end

  local all, failures, ran = {}, {}, {}
  ---@type table<string, vim.quickfix.entry[]>
  local found = {}
  require('util.system').each(tools, M.LIMIT, function(tool, done)
    if tool.runs_code then
      local question = ('Run %s in %s?\nIt loads the configuration of the project as you.'):format(
        tool.name,
        vim.fn.fnamemodify(root, ':~')
      )
      if not require('util.trust').ask('deadcode', root, question) then
        table.insert(
          failures,
          tool.name .. ' not run: the project is not trusted'
        )
        return done()
      end
    end
    run_one(tool, root, function(items, failure)
      found[tool.name] = items
      if failure then
        table.insert(failures, failure)
      else
        table.insert(ran, tool.name)
      end
      done()
    end)
  end, function()
    local counts = {}
    -- In the order of `M.TOOLS`, whichever finished first
    for _, tool in ipairs(tools) do
      local items = found[tool.name] or {}
      vim.list_extend(all, items)
      if #items > 0 then
        table.insert(counts, ('%s %d'):format(tool.name, #items))
      end
    end
    for _, failure in ipairs(failures) do
      notify(failure, vim.log.levels.ERROR)
    end
    if #all > 0 then
      vim.fn.setqflist({}, ' ', { title = 'Dead code', items = all })
      vim.cmd('botright copen')
      notify(
        ('%d unused (%s)'):format(#all, table.concat(counts, ', ')),
        vim.log.levels.WARN
      )
    elseif #failures == 0 then
      notify(('No dead code (%s)'):format(table.concat(ran, ', ')))
    end
  end)
end

return M
