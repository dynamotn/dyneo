--- Architecture decision records, kept the way adr-tools keeps them
---
--- One Markdown file per decision, `NNNN-title.md`, in the directory a
--- `.adr-dir` file at the root names, else `docs/adr`, `doc/adr` or
--- `docs/decisions` when one exists, else `docs/adr`. Each has a status --
--- proposed, accepted, deprecated, superseded -- and a decision that
--- replaces another links both ways, so the record says which one holds.
local M = {}

--- Where the records are looked for, in order, under the root
M.DIRS = { 'docs/adr', 'doc/adr', 'docs/decisions', 'adr' }

--- The statuses a record can have
M.STATUSES = { 'Proposed', 'Accepted', 'Deprecated', 'Superseded' }

local notify = require('util.notify').titled('ADR')

--- A title as a file name: `Use Postgres for jobs` -> `use-postgres-for-jobs`
---@param title string
---@return string
function M.slug(title)
  local slug =
    title:lower():gsub('[^%w]+', '-'):gsub('^%-+', ''):gsub('%-+$', '')
  return slug ~= '' and slug or 'decision'
end

---@class DyAdr
---@field number integer
---@field title string
---@field status string
---@field file string

--- What a record says of itself: `# 3. Title` and the line after `## Status`
---@param lines string[]
---@param file string
---@return DyAdr?
function M.parse(lines, file)
  local number = tonumber(vim.fs.basename(file):match('^(%d+)%-'))
  if not number then return nil end
  local title, status, in_status = nil, nil, false
  for _, line in ipairs(lines) do
    title = title or line:match('^#%s+%d+%.%s+(.-)%s*$') or nil
    if line:match('^##%s+Status%s*$') then
      in_status = true
    elseif in_status and line:match('^##%s') then
      in_status = false
    elseif in_status and not status and line:match('%S') then
      status = vim.trim(line)
    end
  end
  return {
    number = number,
    title = title or vim.fs.basename(file),
    status = status or '?',
    file = file,
  }
end

--- The lines of a new record
---@param number integer
---@param title string
---@param date string
---@param status? string `Proposed` unless given
---@return string[]
function M.template(number, title, date, status)
  return {
    ('# %d. %s'):format(number, title),
    '',
    'Date: ' .. date,
    '',
    '## Status',
    '',
    status or 'Proposed',
    '',
    '## Context',
    '',
    'What is the issue that motivates this decision or change?',
    '',
    '## Decision',
    '',
    'What is the change that is proposed or done?',
    '',
    '## Consequences',
    '',
    'What becomes easier or harder because of it?',
  }
end

--- `lines` with the text of their `## Status` section replaced by `status`
---@param lines string[]
---@param status string|string[]
---@return string[]
function M.set_status(lines, status)
  local out, skipping, done = {}, false, false
  local replacement = type(status) == 'table' and status or { status }
  for _, line in ipairs(lines) do
    if not done and line:match('^##%s+Status%s*$') then
      table.insert(out, line)
      table.insert(out, '')
      vim.list_extend(out, replacement)
      table.insert(out, '')
      skipping, done = true, true
    elseif skipping and line:match('^#') then
      skipping = false
      table.insert(out, line)
    elseif not skipping then
      table.insert(out, line)
    end
  end
  if not done then
    vim.list_extend(out, { '', '## Status', '' })
    vim.list_extend(out, replacement)
  end
  return out
end

--- The project root of the current buffer
---@return string
local function root()
  return vim.fs.root(0, { '.git', '.adr-dir' }) or vim.uv.cwd() --[[@as string]]
end

--- `path` with its symlinks resolved, as far as it exists
---@param path string
---@return string
local function resolved(path)
  local rest = ''
  while true do
    local real = vim.uv.fs_realpath(path)
    if real then return real .. rest end
    local parent = vim.fs.dirname(path)
    if parent == path then return path .. rest end
    rest = '/' .. vim.fs.basename(path) .. rest
    path = parent
  end
end

--- The directory of the records of the project at `base`; nil with why when
--- its `.adr-dir` points outside it
---@param base string
---@return string? dir
---@return string? err
function M.dir(base)
  local marker = vim.fs.joinpath(base, '.adr-dir')
  if vim.fn.filereadable(marker) == 1 then
    local line = vim.trim(vim.fn.readfile(marker)[1] or '')
    if line ~= '' then
      local dir = vim.fs.normalize(vim.fs.joinpath(base, line))
      -- A cloned repository chooses the line: it must not have records
      -- written, or directories made, outside it
      if
        not require('util.root').contains(
          resolved(vim.fs.normalize(base)),
          resolved(dir)
        )
      then
        return nil, ('`.adr-dir` points outside the project: %s'):format(line)
      end
      return dir
    end
  end
  -- A cloned repository may hold `docs/adr` as a link elsewhere just as
  -- well: each folder is held to the project the way `.adr-dir` is
  local function inside(path)
    return require('util.root').contains(
      resolved(vim.fs.normalize(base)),
      resolved(path)
    )
  end
  for _, dir in ipairs(M.DIRS) do
    local path = vim.fs.joinpath(base, dir)
    if vim.fn.isdirectory(path) == 1 then
      if not inside(path) then
        return nil, ('`%s` points outside the project'):format(dir)
      end
      return path
    end
  end
  local path = vim.fs.joinpath(base, M.DIRS[1])
  if not inside(path) then
    return nil, ('`%s` points outside the project'):format(M.DIRS[1])
  end
  return path
end

--- Every record of `dir`, by number
---@param dir string
---@return DyAdr[]
function M.list(dir)
  local records = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and name:match('^%d+%-.*%.md$') then
      local file = vim.fs.joinpath(dir, name)
      local ok, lines = pcall(vim.fn.readfile, file, '', 40)
      local record = M.parse(ok and lines or {}, file)
      if record then table.insert(records, record) end
    end
  end
  table.sort(records, function(a, b) return a.number < b.number end)
  return records
end

--- A new record titled `title` in `dir`, written and returned; nil and why
--- when something is already at its name -- a link put there would have
--- the record written wherever it points
---@param dir string
---@param title string
---@param status? string
---@return DyAdr? record
---@return string? err
function M.create(dir, title, status)
  local records = M.list(dir)
  local number = #records > 0 and records[#records].number + 1 or 1
  local file =
    vim.fs.joinpath(dir, ('%04d-%s.md'):format(number, M.slug(title)))
  if vim.uv.fs_lstat(file) then
    return nil, ('%s is there already, and is no record'):format(file)
  end
  vim.fn.mkdir(dir, 'p')
  vim.fn.writefile(
    M.template(number, title, os.date('%Y-%m-%d') --[[@as string]], status),
    file
  )
  return {
    number = number,
    title = title,
    status = status or 'Proposed',
    file = file,
  }
end

--- A Markdown link to `record`, relative to the directory of the records
---@param record DyAdr
---@return string
local function link(record)
  return ('[%d. %s](%s)'):format(
    record.number,
    record.title,
    vim.fs.basename(record.file)
  )
end

--- Ask for a title when none is given, then call `fn` with it
---@param title? string
---@param fn fun(title: string)
local function with_title(title, fn)
  if title and title ~= '' then return fn(title) end
  vim.ui.input({ prompt = 'Decision: ' }, function(input)
    if input and vim.trim(input) ~= '' then fn(vim.trim(input)) end
  end)
end

--- Write a new record and open it
---@param title? string
function M.new(title)
  with_title(title, function(text)
    local dir, err = M.dir(root())
    if not dir then return notify(err, vim.log.levels.ERROR) end
    local record, why = M.create(dir, text)
    if not record then return notify(why, vim.log.levels.ERROR) end
    vim.cmd.edit(vim.fn.fnameescape(record.file))
    notify(('Recorded %d. %s'):format(record.number, record.title))
  end)
end

--- The record of the current buffer, or nil with a warning
---@return DyAdr?
local function current()
  local file = vim.api.nvim_buf_get_name(0)
  local record = file ~= ''
    and M.parse(vim.api.nvim_buf_get_lines(0, 0, -1, false), file)
  if not record then
    notify('This buffer is no decision record', vim.log.levels.WARN)
  end
  return record or nil
end

--- Set the status of the record of the current buffer
---@param status? string Asked for when not given
function M.status(status)
  local record = current()
  if not record then return end
  if not status then
    return vim.ui.select(M.STATUSES, { prompt = 'Status' }, function(choice)
      if choice then M.status(choice) end
    end)
  end
  local word = status:sub(1, 1):upper() .. status:sub(2):lower()
  if not vim.list_contains(M.STATUSES, word) then
    return notify('Unknown status: ' .. status, vim.log.levels.ERROR)
  end
  local lines = M.set_status(vim.api.nvim_buf_get_lines(0, 0, -1, false), word)
  vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
end

--- Write a record that supersedes the one of the current buffer, linking
--- both ways, and open it
---@param title? string
function M.supersede(title)
  local old = current()
  if not old then return end
  local bufnr = vim.api.nvim_get_current_buf()
  with_title(title, function(text)
    local new, why = M.create(vim.fs.dirname(old.file), text, 'Accepted')
    if not new then return notify(why, vim.log.levels.ERROR) end
    vim.api.nvim_buf_set_lines(
      bufnr,
      0,
      -1,
      false,
      M.set_status(
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
        { 'Superseded', '', 'Superseded by ' .. link(new) }
      )
    )
    vim.api.nvim_buf_call(bufnr, function() vim.cmd('silent write') end)
    local lines = M.set_status(
      vim.fn.readfile(new.file),
      { 'Accepted', '', 'Supersedes ' .. link(old) }
    )
    vim.fn.writefile(lines, new.file)
    vim.cmd.edit(vim.fn.fnameescape(new.file))
  end)
end

--- Pick a record of the project and open it
function M.pick()
  local dir, err = M.dir(root())
  if not dir then return notify(err, vim.log.levels.ERROR) end
  local records = M.list(dir)
  if #records == 0 then
    return notify('No decision recorded yet: `:DyAdr new` starts one')
  end
  vim.ui.select(records, {
    prompt = 'Decisions',
    format_item = function(record)
      return ('%04d  %-10s  %s'):format(
        record.number,
        record.status,
        record.title
      )
    end,
  }, function(record)
    if record then vim.cmd.edit(vim.fn.fnameescape(record.file)) end
  end)
end

--- The subcommands of `:DyAdr`
M.SUBCOMMANDS = { 'new', 'list', 'status', 'supersede' }

--- `:DyAdr new [{title}]`, `:DyAdr list`, `:DyAdr status [{status}]`,
--- `:DyAdr supersede [{title}]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1] or 'list'
  local rest = table.concat(vim.list_slice(args.fargs, 2), ' ')
  rest = rest ~= '' and rest or nil
  if sub == 'new' then return M.new(rest) end
  if sub == 'list' then return M.pick() end
  if sub == 'status' then return M.status(rest) end
  if sub == 'supersede' then return M.supersede(rest) end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
