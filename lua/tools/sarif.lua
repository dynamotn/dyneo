--- The findings of a SARIF report, on the lines they are about
---
--- SARIF is what most code scanners write: semgrep, CodeQL, gosec, trivy,
--- checkov, bandit. `:DySarif` reads one and lists every result in the
--- quickfix list, worst first, so a report from CI is walked with `]q`.
--- Nothing runs: the report is only read.
local M = {}

--- The most of a report read. It is read and decoded on the main loop, which
--- takes about 0.2 s at this size; a larger report is better filtered first.
M.MAX_REPORT = 16 * 1024 * 1024

local notify = require('util.notify').titled('SARIF')

local TYPES = { error = 'E', warning = 'W', note = 'N', none = 'I' }
local RANK = { E = 1, W = 2, N = 3, I = 4 }

--- The absolute path of a result's artifact. A relative URI is read against
--- the base the report gives it (`originalUriBaseIds`), else against `root`.
---@param location table `physicalLocation.artifactLocation`
---@param bases table `run.originalUriBaseIds`
---@param root string
---@return string?
local function path_of(location, bases, root)
  local uri = type(location.uri) == 'string' and location.uri or nil
  if not uri then return nil end
  if uri:match('^file:') then return vim.fs.normalize(vim.uri_to_fname(uri)) end
  if uri:match('^%a[%w+.-]*:') then return nil end
  uri = vim.uri_decode(uri)
  if uri:sub(1, 1) == '/' then return vim.fs.normalize(uri) end
  local base = location.uriBaseId and bases[location.uriBaseId]
  local base_uri = type(base) == 'table' and base.uri or nil
  if type(base_uri) == 'string' and base_uri:match('^file:') then
    root = vim.uri_to_fname(base_uri)
  end
  return vim.fs.normalize(vim.fs.joinpath(root, uri))
end

--- The quickfix item of one `result`; raises on one that is not SARIF
---@param result table
---@param tool string
---@param bases table
---@param root string The project root, symlinks resolved
---@return vim.quickfix.entry
local function item_of(result, tool, bases, root)
  assert(type(result) == 'table', 'a result is not an object')
  local physical = vim.tbl_get(result, 'locations', 1, 'physicalLocation') or {}
  local region = physical.region or {}
  local filename = path_of(physical.artifactLocation or {}, bases, root)
  local message = vim.tbl_get(result, 'message', 'text') or ''
  assert(type(message) == 'string', 'message.text is not a string')
  local text = ('[%s %s] %s'):format(
    tool,
    type(result.ruleId) == 'string' and result.ruleId or '?',
    -- One line: a multi-line message would break the list up
    (message:gsub('%s*\n%s*', ' '))
  )
  -- A report is no reason to open a file outside the project it is about:
  -- `../..`, `file:///etc/shadow` or a base of its own can point anywhere
  if
    filename
    and not require('util.root').contains(
      root,
      vim.uv.fs_realpath(filename) or filename
    )
  then
    text = ('%s (outside the project: %s)'):format(text, filename)
    filename = nil
  end
  return {
    filename = filename,
    lnum = tonumber(region.startLine) or 1,
    col = tonumber(region.startColumn) or 1,
    end_lnum = tonumber(region.endLine),
    type = TYPES[result.level] or 'W',
    text = text,
    valid = filename ~= nil,
  }
end

--- The quickfix items of a decoded SARIF `report`, worst first
---@param report table
---@param root string The project root, where relative paths start
---@return vim.quickfix.entry[]
---@return integer skipped Results that are not SARIF
function M.items(report, root)
  root = vim.uv.fs_realpath(root) or vim.fs.normalize(root)
  local items, skipped = {}, 0
  for _, run in ipairs(type(report.runs) == 'table' and report.runs or {}) do
    if type(run) ~= 'table' then
      skipped = skipped + 1
    else
      local bases = type(run.originalUriBaseIds) == 'table'
          and run.originalUriBaseIds
        or {}
      local tool = vim.tbl_get(run, 'tool', 'driver', 'name')
      tool = type(tool) == 'string' and tool or 'sarif'
      local results = type(run.results) == 'table' and run.results or {}
      for _, result in ipairs(results) do
        local ok, item = pcall(item_of, result, tool, bases, root)
        if ok then
          table.insert(items, item)
        else
          skipped = skipped + 1
        end
      end
    end
  end
  table.sort(items, function(a, b)
    if a.type ~= b.type then return RANK[a.type] < RANK[b.type] end
    if (a.filename or '') ~= (b.filename or '') then
      return (a.filename or '') < (b.filename or '')
    end
    return a.lnum < b.lnum
  end)
  return items, skipped
end

--- Read the report at `path` into the quickfix list
---@param path string
function M.load(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local stat = vim.uv.fs_stat(path)
  if not stat then
    return notify(path .. ' does not exist', vim.log.levels.ERROR)
  end
  if stat.size > M.MAX_REPORT then
    return notify(
      ('%s is over %d MiB, not read'):format(path, M.MAX_REPORT / 1048576),
      vim.log.levels.ERROR
    )
  end
  local file = io.open(path, 'rb')
  local text = file and file:read('*a')
  if file then file:close() end
  local ok, report = pcall(
    vim.json.decode,
    text or '',
    { luanil = { object = true, array = true } }
  )
  if not ok or type(report) ~= 'table' or type(report.runs) ~= 'table' then
    return notify(path .. ' is not a SARIF report', vim.log.levels.ERROR)
  end
  local root = vim.fs.root(path, '.git') or vim.fs.dirname(path)
  local items, skipped = M.items(report, root)
  if skipped > 0 then
    notify(
      ('%d results of %s are not SARIF, not listed'):format(skipped, path),
      vim.log.levels.WARN
    )
  end
  vim.fn.setqflist({}, ' ', { title = 'SARIF: ' .. path, items = items })
  if #items == 0 then
    if skipped == 0 then notify('No findings in ' .. path) end
    return
  end
  vim.cmd('botright copen')
end

--- `:DySarif [{path}]`: the report given, the buffer when it is one, or
--- asked for
---@param args vim.api.keyset.create_user_command.command_args
function M.command(args)
  if args.args ~= '' then return M.load(args.args) end
  local name = vim.api.nvim_buf_get_name(0)
  if name:match('%.sarif$') or name:match('%.sarif%.json$') then
    return M.load(name)
  end
  vim.ui.input(
    { prompt = 'SARIF report: ', completion = 'file' },
    function(path)
      if path and path ~= '' then M.load(path) end
    end
  )
end

return M
