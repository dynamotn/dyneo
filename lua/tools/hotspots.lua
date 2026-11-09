--- The files of a project most worth refactoring or reviewing
---
--- A hotspot is code that is both complex and often changed ("code as a
--- crime scene"). Churn is the number of commits that touched a file since
--- `M.SINCE`, from `git log --numstat`; complexity is the sum of the
--- cyclomatic complexity (CCN) of the file's functions, from lizard, so a
--- file of many tangled functions ranks above one with a single bad one. The
--- score is their product. Only files git still tracks count, and lockfiles,
--- vendored and minified files never do.
---
--- `M.buffer` marks the functions of one buffer above `M.CCN_WARN` as hints,
--- from one lizard run on its file, until toggled off.
local M = {}

local notify = require('util.notify').titled('Hotspots')

--- How far back churn is counted, as `git log --since` reads it
M.SINCE = '12 months ago'

--- Files listed
M.LIMIT = 20

--- The CCN above which `M.buffer` marks a function: lizard's own warning
M.CCN_WARN = 15

--- The most churned files handed to lizard, the rest cannot rank high
M.MAX_FILES = 1000

--- Milliseconds git or lizard may take
M.TIMEOUT = 120 * 1000

--- Output kept of git or lizard
M.MAX_BYTES = 16 * 1024 * 1024

--- Lua patterns of the paths that are generated or vendored
M.EXCLUDE = {
  '%.lock$',
  '[%.-]lock%.[%w]+$',
  '^go%.sum$',
  '/go%.sum$',
  '^vendor/',
  '/vendor/',
  '^node_modules/',
  '/node_modules/',
  '%.min%.[%w]+$',
}

local ns = vim.api.nvim_create_namespace('dy_hotspots')

--- Whether `path` is generated or vendored
---@param path string
---@return boolean
function M.excluded(path)
  for _, pattern in ipairs(M.EXCLUDE) do
    if path:match(pattern) then return true end
  end
  return false
end

--- The commits that touched each file of `tracked`, from the output of
--- `git log --numstat --format=`: one `added<Tab>deleted<Tab>path` line per
--- file a commit touched
---@param text string
---@param tracked table<string, boolean>
---@return table<string, integer>
function M.churn(text, tracked)
  local commits = {}
  for line in vim.gsplit(text, '\n', { trimempty = true }) do
    -- shortcut: a path git quotes (tabs, quotes, newlines in it) is skipped
    local path = line:match('^[%d-]+\t[%d-]+\t(.+)$')
    if path and tracked[path] and not M.excluded(path) then
      commits[path] = (commits[path] or 0) + 1
    end
  end
  return commits
end

---@class DyHotspotFunction
---@field file string
---@field name string
---@field ccn integer
---@field nloc integer
---@field lnum integer
---@field end_lnum integer

--- The functions in the output of `lizard --csv`: `nloc,ccn,tokens,params,
--- length,"name@start-end@file","file","name","long name",start,end`
---@param text string
---@return DyHotspotFunction[]
function M.functions(text)
  local found = {}
  for line in vim.gsplit(text, '\n', { trimempty = true }) do
    local nloc, ccn, quoted, lnum, end_lnum =
      line:match('^(%d+),(%d+),%d+,%d+,%d+,(.*),(%d+),(%d+)$')
    -- shortcut: a file or function name holding `","` is misread
    local file, name = (quoted or ''):match('^".-","(.-)","(.-)",".*"$')
    if file then
      table.insert(found, {
        file = file,
        name = name,
        ccn = tonumber(ccn),
        nloc = tonumber(nloc),
        lnum = tonumber(lnum),
        end_lnum = tonumber(end_lnum),
      })
    end
  end
  return found
end

---@class DyHotspot
---@field file string
---@field commits integer
---@field ccn integer Sum of the CCN of its functions
---@field score integer
---@field worst DyHotspotFunction

--- The files of `churn` that have functions, the highest score first
---@param churn table<string, integer>
---@param functions DyHotspotFunction[]
---@return DyHotspot[]
function M.rank(churn, functions)
  ---@type table<string, DyHotspot>
  local by_file = {}
  for _, fn in ipairs(functions) do
    local commits = churn[fn.file]
    if commits then
      local spot = by_file[fn.file]
        or { file = fn.file, commits = commits, ccn = 0, worst = fn }
      spot.ccn = spot.ccn + fn.ccn
      if fn.ccn > spot.worst.ccn then spot.worst = fn end
      by_file[fn.file] = spot
    end
  end
  local spots = {}
  for _, spot in pairs(by_file) do
    spot.score = spot.commits * spot.ccn
    table.insert(spots, spot)
  end
  table.sort(spots, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    return a.file < b.file
  end)
  return spots
end

--- Run lizard on `files`, relative to `cwd`, and hand `done` the functions
--- found, or why it failed; one run, the list in a file so the command line
--- stays short
---@param files string[]
---@param cwd string
---@param done fun(functions?: DyHotspotFunction[], failure?: string, cut?: boolean)
local function lizard(files, cwd, done)
  local list = vim.fn.tempname()
  vim.fn.writefile(files, list)
  local system = require('util.system')
  system.run(
    { 'lizard', '--csv', '-f', list },
    { cwd = cwd, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      vim.fn.delete(list)
      if result.missing then
        require('util.lazy_install').install_once('lizard')
        return done(
          nil,
          'lizard is not installed: Mason installs it, run again once it is done'
        )
      end
      if result.timed_out or (result.code ~= 0 and not result.cut) then
        return done(nil, system.failure(result, 'lizard'))
      end
      local text = result.stdout or ''
      -- What was cut ends mid-line
      if result.cut then text = text:gsub('[^\n]*$', '') end
      done(M.functions(text), nil, result.cut)
    end
  )
end

--- The quickfix item of `spot`, at its worst function
---@param root string
---@param spot DyHotspot
---@return vim.quickfix.entry
local function item(root, spot)
  return {
    filename = vim.fs.joinpath(root, spot.file),
    lnum = spot.worst.lnum,
    text = ('score %d: %d commits x CCN %d; worst %s (CCN %d)'):format(
      spot.score,
      spot.commits,
      spot.ccn,
      spot.worst.name,
      spot.worst.ccn
    ),
  }
end

--- List the hotspots of the project of the buffer in the quickfix list
function M.run()
  local root = require('util.root')()
  local system = require('util.system')
  local opts = { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES }
  system.run({ 'git', 'ls-files', '-z' }, opts, function(files)
    if files.missing or files.code ~= 0 or files.cut or files.timed_out then
      return notify(
        ('Not a git repository, or git failed: %s'):format(
          system.failure(files, 'git ls-files')
        ),
        vim.log.levels.ERROR
      )
    end
    local tracked = {}
    for path in vim.gsplit(files.stdout, '\0', { trimempty = true }) do
      tracked[path] = true
    end
    system.run(
      {
        'git',
        '-c',
        'core.quotePath=false',
        'log',
        '--since=' .. M.SINCE,
        '--no-renames',
        '--relative',
        '--numstat',
        '--format=',
      },
      opts,
      function(log)
        if log.missing or log.timed_out or (log.code ~= 0 and not log.cut) then
          return notify(system.failure(log, 'git log'), vim.log.levels.ERROR)
        end
        if log.cut then
          notify(
            'The history was cut at its size cap: churn counts only the newest commits',
            vim.log.levels.WARN
          )
        end
        local churn = M.churn(log.stdout, tracked)
        local paths = vim.tbl_keys(churn)
        if #paths == 0 then
          return notify(('No tracked file changed since %s'):format(M.SINCE))
        end
        table.sort(paths, function(a, b)
          if churn[a] ~= churn[b] then return churn[a] > churn[b] end
          return a < b
        end)
        paths = vim.list_slice(paths, 1, M.MAX_FILES)
        lizard(paths, root, function(functions, failure, cut)
          if not functions then return notify(failure, vim.log.levels.ERROR) end
          if cut then
            notify(
              'lizard printed more than can be read: some files are left out',
              vim.log.levels.WARN
            )
          end
          local spots = M.rank(churn, functions)
          if #spots == 0 then
            return notify(
              ('No function lizard knows in the files changed since %s'):format(
                M.SINCE
              )
            )
          end
          local items = {}
          for i = 1, math.min(M.LIMIT, #spots) do
            table.insert(items, item(root, spots[i]))
          end
          vim.fn.setqflist({}, ' ', { title = 'Hotspots', items = items })
          vim.cmd('botright copen')
        end)
      end
    )
  end)
end

--- Mark the functions of `bufnr` above `M.CCN_WARN`, from its file as saved
---@param bufnr integer
local function mark(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  lizard({ file }, vim.fs.dirname(file), function(functions, failure)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not functions then return notify(failure, vim.log.levels.ERROR) end
    local diagnostics = {}
    for _, fn in ipairs(functions) do
      if fn.ccn > M.CCN_WARN then
        table.insert(diagnostics, {
          lnum = fn.lnum - 1,
          end_lnum = fn.end_lnum - 1,
          col = 0,
          severity = vim.diagnostic.severity.HINT,
          source = 'lizard',
          message = ('%s: cyclomatic complexity %d, over %d'):format(
            fn.name,
            fn.ccn,
            M.CCN_WARN
          ),
        })
      end
    end
    vim.diagnostic.set(ns, bufnr, diagnostics)
    if #diagnostics == 0 then
      notify(('No function over CCN %d'):format(M.CCN_WARN))
    end
  end)
end

--- Toggle the marks of the complex functions of `bufnr`; while on, they are
--- read again after each write
---@param bufnr? integer
function M.buffer(bufnr)
  if not bufnr or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local group =
    vim.api.nvim_create_augroup('dy_hotspots_' .. bufnr, { clear = true })
  if vim.b[bufnr].dy_hotspots then
    vim.b[bufnr].dy_hotspots = nil
    vim.api.nvim_del_augroup_by_id(group)
    vim.diagnostic.reset(ns, bufnr)
    return
  end
  if vim.api.nvim_buf_get_name(bufnr) == '' or vim.bo[bufnr].buftype ~= '' then
    return notify('The buffer is not a file', vim.log.levels.WARN)
  end
  if vim.bo[bufnr].modified then
    notify('Marking the file as saved, not the unsaved changes')
  end
  vim.b[bufnr].dy_hotspots = true
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    buffer = bufnr,
    callback = function()
      if vim.v.exiting ~= vim.NIL then return end
      mark(bufnr)
    end,
  })
  mark(bufnr)
end

return M
