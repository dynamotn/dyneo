--- Data files read through DuckDB: what a Parquet, CSV or JSON file holds,
--- and SQL run over them
---
--- A data file is mostly too large or too binary to read as text. DuckDB
--- reads each of these formats itself, so a file is summed up in one run of
--- its CLI: how many rows, the columns and their types, the first rows, and
--- on asking the statistics of every column. Opening a `.parquet` file shows
--- that summary in place of its bytes, in a buffer that cannot be written
--- back over the file.
---
--- `:DyData sql` runs the lines given, or the selection, as a DuckDB script
--- from the working directory, so a `.sql` file next to the data reads it by
--- its relative path. The CLI's own dot commands run too, and some reach
--- past SQL -- `.shell`, `.system`, `.read` another file, `.output` over one
--- -- so a script holding any but those in `M.DOT_COMMANDS` is refused:
--- a `.sql` file from someone else's repository runs no shell command.
---
--- One run at a time per window: a new one stops the last, and so does
--- closing the window or leaving Neovim. Every run has a deadline, and its
--- output is cut at `M.MAX_OUTPUT` and says so. DuckDB is never let to
--- download an extension on its own: a format that needs one fails rather
--- than reaching the network.
---
--- What a run prints is rows of the user's data, which may be personal: the
--- window showing it is kept from every AI integration.
local M = {}

--- Milliseconds a run may take
M.TIMEOUT = 60 * 1000
--- Bytes of output kept
M.MAX_OUTPUT = 1024 * 1024
--- Rows a summary shows, and the most a query result shows
M.ROWS = 50
--- Why every window of this module is kept from AI
M.SENSITIVE = 'rows read from a data file'
--- The subcommands of `:DyData`
M.SUBCOMMANDS = { 'stats', 'sql' }
--- Dot commands a script may hold: those that only shape what is printed
M.DOT_COMMANDS = {
  'columns',
  'headers',
  'maxrows',
  'maxwidth',
  'mode',
  'nullvalue',
  'print',
  'rows',
  'separator',
  'timer',
  'width',
}

--- The DuckDB function reading each extension. A compressed file is read
--- through the same one once its `.gz` or `.zst` is taken off.
M.READERS = {
  parquet = 'read_parquet',
  csv = 'read_csv',
  tsv = 'read_csv',
  psv = 'read_csv',
  json = 'read_json',
  jsonl = 'read_json',
  ndjson = 'read_json',
}

local notify = require('util.notify').titled('Data')

--- The DuckDB function that reads `path`, or nil for a format it does not
---@param path string
---@return string?
function M.reader(path)
  local name =
    vim.fs.basename(path):lower():gsub('%.gz$', ''):gsub('%.zst$', '')
  local ext = name:match('%.([^.]+)$')
  return ext and M.READERS[ext] or nil
end

--- `text` as a SQL string literal
---@param text string
---@return string
function M.quote(text) return "'" .. text:gsub("'", "''") .. "'" end

--- The table expression reading `path`
---@param path string
---@return string?
function M.source(path)
  local reader = M.reader(path)
  if not reader then return nil end
  return ('%s(%s)'):format(reader, M.quote(path))
end

--- The lines every script starts with: tables that show their first and
--- last `maxrows` rows, no extension fetched on its own, none but DuckDB's
--- signed ones loaded -- a community one such as `shellfs` would run shell
--- commands from SQL -- and the configuration locked, so a script cannot
--- turn either back on
---@param maxrows integer
---@return string[]
local function prelude(maxrows)
  return {
    'SET autoinstall_known_extensions = false;',
    'SET allow_community_extensions = false;',
    'SET lock_configuration = true;',
    '.mode duckbox',
    ('.maxrows %d'):format(maxrows),
  }
end

--- The DuckDB script summing up `path`: rows, columns, first rows, and the
--- statistics of every column when `stats` is set
---@param path string
---@param stats? boolean
---@return string[]?
function M.summary_script(path, stats)
  local source = M.source(path)
  if not source then return nil end
  -- Every column is listed, however many: only the rows are limited, by
  -- the query
  local script = prelude(100000)
  vim.list_extend(script, {
    '.print Rows',
    ('SELECT count(*) AS rows FROM %s;'):format(source),
    '.print',
    '.print Columns',
    ('DESCRIBE SELECT * FROM %s;'):format(source),
    '.print',
  })
  if stats then
    vim.list_extend(script, {
      '.print Statistics',
      ('SUMMARIZE SELECT * FROM %s;'):format(source),
    })
  else
    vim.list_extend(script, {
      ('.print First %d rows'):format(M.ROWS),
      ('SELECT * FROM %s LIMIT %d;'):format(source, M.ROWS),
    })
  end
  return script
end

--- The command running a script read from stdin, on a database in memory.
--- It stops at the first error, which is then the last thing printed:
--- stdout and stderr are read apart and could not be put back in order.
---@return string[]
function M.argv() return { 'duckdb', '-batch', '-no-init', '-bail', ':memory:' } end

--- The first dot command of `lines` not in `M.DOT_COMMANDS`, if any
---@param lines string[]
---@return string? command
---@return integer? line
function M.forbidden(lines)
  for number, line in ipairs(lines) do
    local command = line:match('^%s*%.(%S*)')
    if command and not vim.list_contains(M.DOT_COMMANDS, command) then
      return '.' .. command, number
    end
  end
end

--- The lines to show for a finished run
---@param result DyRunResult
---@return string[]
function M.output(result)
  local lines = {}
  local text = (result.stdout or '') .. (result.stderr or '')
  if text ~= '' then lines = vim.split(text, '\n', { trimempty = true }) end
  if result.cut then
    table.insert(
      lines,
      ('[cut at %d KiB]'):format(math.floor(M.MAX_OUTPUT / 1024))
    )
  elseif result.missing or result.timed_out then
    table.insert(lines, require('util.system').failure(result, 'duckdb'))
  elseif result.code ~= 0 and #lines == 0 then
    table.insert(lines, ('duckdb exited %d'):format(result.code))
  end
  return lines
end

--- The run going on for each buffer showing one
---@type table<integer, vim.SystemObj>
M.jobs = {}

--- Stop the run going on for `bufnr`, if any
---@param bufnr integer
function M.stop(bufnr)
  local job = M.jobs[bufnr]
  M.jobs[bufnr] = nil
  if job then pcall(job.kill, job, 'sigterm') end
end

local group = vim.api.nvim_create_augroup('dy_data_jobs', { clear = true })
vim.api.nvim_create_autocmd('VimLeavePre', {
  group = group,
  callback = function()
    for bufnr in pairs(M.jobs) do
      M.stop(bufnr)
    end
  end,
  desc = 'Stop every DuckDB run on leaving',
})

--- Buffers whose unloading stops their run
---@type table<integer, true>
local watched = {}

--- Run `script` and put what it prints in `bufnr`, stopping any run still
--- going for that buffer
---@param bufnr integer
---@param script string[]
---@param opts? { cwd?: string, title?: string }
function M.run_into(bufnr, script, opts)
  opts = opts or {}
  local scratch = require('util.scratch')
  M.stop(bufnr)
  if not watched[bufnr] then
    watched[bufnr] = true
    vim.api.nvim_create_autocmd('BufUnload', {
      group = group,
      buffer = bufnr,
      once = true,
      callback = function()
        watched[bufnr] = nil
        M.stop(bufnr)
      end,
      desc = 'Stop the DuckDB run of the buffer',
    })
  end
  scratch.set(bufnr, {
    ('Running duckdb%s…'):format(opts.title and (' on ' .. opts.title) or ''),
  })
  local job
  job = require('util.system').run(M.argv(), {
    cwd = opts.cwd,
    stdin = table.concat(script, '\n') .. '\n',
    timeout = M.TIMEOUT,
    max_bytes = M.MAX_OUTPUT,
  }, function(result)
    -- A later run replaced this one: what it printed is no longer wanted
    if M.jobs[bufnr] ~= job then return end
    M.jobs[bufnr] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    scratch.set(bufnr, M.output(result))
    if result.missing then
      notify(
        'duckdb is not installed (`:MasonInstall duckdb`)',
        vim.log.levels.ERROR
      )
    end
  end)
  M.jobs[bufnr] = job
end

--- Whether `path` is a pattern, which DuckDB reads as every file it matches
---@param path string
---@return boolean
local function is_glob(path) return path:find('[*?[]') ~= nil end

--- The file `arg` names, or the file of the current buffer. A pattern is
--- left for DuckDB to match, where `expand` would list the files.
---@param arg? string
---@return string?
local function target(arg)
  local path
  if not arg or arg == '' then
    path = vim.api.nvim_buf_get_name(0)
  elseif is_glob(arg) then
    path = arg
  else
    path = vim.fn.expand(arg)
  end
  if path == '' then return nil end
  return vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
end

--- Sum up a data file in a tab of its own
---@param path? string The file of the current buffer when nil
---@param stats? boolean
function M.summary(path, stats)
  path = target(path)
  if not path then return notify('No file given', vim.log.levels.WARN) end
  local script = M.summary_script(path, stats)
  if not script then
    return notify(
      ('DuckDB reads none of %s'):format(vim.fn.fnamemodify(path, ':t')),
      vim.log.levels.WARN
    )
  end
  if not is_glob(path) and not vim.uv.fs_stat(path) then
    return notify(
      ('%s does not exist'):format(vim.fn.fnamemodify(path, ':~')),
      vim.log.levels.WARN
    )
  end
  local bufnr = require('util.scratch').open({}, {
    name = ('dydata://%s%s'):format(stats and 'stats/' or '', path),
    sensitive = M.SENSITIVE,
  })
  vim.wo.wrap = false
  M.run_into(bufnr, script, { title = vim.fn.fnamemodify(path, ':t') })
end

--- Show the summary of a data file in its own buffer, read through
--- `BufReadCmd`, in place of its bytes
---@param bufnr integer
function M.read(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  -- `fugitive://`, `scp://`, `oil://`: a buffer another plugin reads
  if name:match('^%a[%w+.-]*://') then return end
  local path = vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
  require('util.sensitive').mark(bufnr, M.SENSITIVE)
  -- The summary is no copy of the file: it must never be written over it
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'dydata'
  for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
    vim.wo[win].wrap = false
  end
  local script = M.summary_script(path)
  if not script then return end
  M.run_into(bufnr, script, { title = vim.fs.basename(path) })
end

--- The window showing results of `:DyData sql`, opened at the bottom when
--- there is none
---@return integer bufnr
local function result_buffer()
  local scratch = require('util.scratch')
  local origin = vim.api.nvim_get_current_win()
  local bufnr = M.result_buf
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    if #vim.fn.win_findbuf(bufnr) == 0 then
      vim.cmd('botright split')
      vim.api.nvim_win_set_buf(0, bufnr)
      vim.wo.wrap = false
      vim.api.nvim_set_current_win(origin)
    end
    return bufnr
  end
  bufnr = scratch.open({}, {
    name = 'dydata://result',
    split = 'horizontal',
    sensitive = M.SENSITIVE,
  })
  -- Shown again, not wiped, so the next run finds it
  vim.bo[bufnr].bufhidden = 'hide'
  vim.wo.wrap = false
  M.result_buf = bufnr
  vim.api.nvim_set_current_win(origin)
  return bufnr
end

--- Run SQL through DuckDB: `query` when given, otherwise lines `line1` to
--- `line2` of the current buffer
---@param query? string
---@param line1? integer
---@param line2? integer
function M.sql(query, line1, line2)
  local lines
  if query and query ~= '' then
    lines = { query }
  else
    lines = vim.api.nvim_buf_get_lines(0, (line1 or 1) - 1, line2 or -1, false)
  end
  if vim.trim(table.concat(lines, '\n')) == '' then
    return notify('No SQL to run', vim.log.levels.WARN)
  end
  local command, number = M.forbidden(lines)
  if command then
    return notify(
      ('Not run: `%s` on line %d reaches past SQL'):format(
        command,
        (line1 or 1) + number - 1
      ),
      vim.log.levels.ERROR
    )
  end
  -- A query over a large table shows its first and last rows, not all
  local script = vim.list_extend(prelude(M.ROWS), lines)
  M.run_into(result_buffer(), script, { cwd = vim.fn.getcwd() })
end

--- `:DyData`
---@param args vim.api.keyset.create_user_command.command_args
function M.command(args)
  local sub, rest = (args.args or ''):match('^(%S*)%s*(.-)$')
  if sub == 'sql' then
    if args.range > 0 or rest ~= '' then
      return M.sql(rest, args.line1, args.line2)
    end
    return M.sql(nil, 1, vim.api.nvim_buf_line_count(0))
  end
  if sub == 'stats' then return M.summary(rest, true) end
  return M.summary(args.args)
end

--- Completion of `:DyData`: a subcommand, then files
---@param lead string
---@param line string
---@return string[]
function M.complete(lead, line)
  local words = vim.split(line, '%s+', { trimempty = false })
  if #words > 2 then
    return words[2] == 'sql' and {} or vim.fn.getcompletion(lead, 'file')
  end
  return vim.list_extend(
    vim.tbl_filter(
      function(word) return word:find(lead, 1, true) == 1 end,
      M.SUBCOMMANDS
    ),
    vim.fn.getcompletion(lead, 'file')
  )
end

return M
