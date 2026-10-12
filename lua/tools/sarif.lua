--- The findings of a SARIF report, on the lines they are about
---
--- SARIF is what most code scanners write: semgrep, CodeQL, gosec, trivy,
--- checkov, bandit. `:DySarif` reads one and lists every result in the
--- quickfix list, worst first, so a report from CI is walked with `]q`.
--- Nothing runs: the report is only read.
local M = {}

--- The most of a report read; CodeQL's of a large repository is big
M.MAX_REPORT = 64 * 1024 * 1024

local notify = require('util.notify').titled('SARIF')

local TYPES = { error = 'E', warning = 'W', note = 'N', none = 'I' }
local RANK = { E = 1, W = 2, N = 3, I = 4 }

--- The path of a result's artifact. A relative URI is read against the base
--- the report gives it (`originalUriBaseIds`), else against `root`.
---@param location table `physicalLocation.artifactLocation`
---@param bases table `run.originalUriBaseIds`
---@param root string
---@return string?
local function path_of(location, bases, root)
  local uri = type(location.uri) == 'string' and location.uri or nil
  if not uri then return nil end
  if uri:match('^file:') then return vim.uri_to_fname(uri) end
  if uri:match('^%a[%w+.-]*:') then return nil end
  local base = location.uriBaseId and bases[location.uriBaseId]
  local base_uri = type(base) == 'table' and base.uri or nil
  if type(base_uri) == 'string' and base_uri:match('^file:') then
    root = vim.uri_to_fname(base_uri)
  end
  return vim.fs.normalize(vim.fs.joinpath(root, vim.uri_decode(uri)))
end

--- The quickfix items of a decoded SARIF `report`, worst first
---@param report table
---@param root string Where relative paths start, usually the project root
---@return vim.quickfix.entry[]
function M.items(report, root)
  local items = {}
  for _, run in ipairs(type(report.runs) == 'table' and report.runs or {}) do
    local bases = type(run.originalUriBaseIds) == 'table'
        and run.originalUriBaseIds
      or {}
    local tool = vim.tbl_get(run, 'tool', 'driver', 'name') or 'sarif'
    for _, result in ipairs(type(run.results) == 'table' and run.results or {}) do
      local physical = vim.tbl_get(result, 'locations', 1, 'physicalLocation')
        or {}
      local region = physical.region or {}
      local filename = path_of(physical.artifactLocation or {}, bases, root)
      local message = vim.tbl_get(result, 'message', 'text') or ''
      table.insert(items, {
        filename = filename,
        lnum = tonumber(region.startLine) or 1,
        col = tonumber(region.startColumn) or 1,
        end_lnum = tonumber(region.endLine),
        type = TYPES[result.level] or 'W',
        -- One line: a multi-line message would break the list up
        text = ('[%s %s] %s'):format(
          tool,
          result.ruleId or '?',
          (message:gsub('%s*\n%s*', ' '))
        ),
        valid = filename ~= nil,
      })
    end
  end
  table.sort(items, function(a, b)
    if a.type ~= b.type then return RANK[a.type] < RANK[b.type] end
    if (a.filename or '') ~= (b.filename or '') then
      return (a.filename or '') < (b.filename or '')
    end
    return a.lnum < b.lnum
  end)
  return items
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
  local items = M.items(report, root)
  vim.fn.setqflist({}, ' ', { title = 'SARIF: ' .. path, items = items })
  if #items == 0 then return notify('No findings in ' .. path) end
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
