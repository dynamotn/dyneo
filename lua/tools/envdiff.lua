--- What differs between two environments' settings, key by key
---
--- `values-dev.yaml` against `values-prod.yaml`, `staging.json` against
--- `production.json`: a line diff of two such files is mostly the noise of
--- keys in another order and lists reindented. `:DyEnvDiff [{other}]` hands
--- the buffer's file and the other -- picked from the files of the same kind
--- beside it when not given -- to `dyff between`, which compares them as
--- documents: each path that differs, with both values. A file dyff cannot
--- read (`*.tfvars`, `.env`) is opened in a diff split instead.
---
--- Both files are compared as they are on disk. What dyff prints holds
--- their values, so it is held back from every AI as a sensitive file is.
local M = {}

local notify = require('util.notify').titled('Env diff')

--- Milliseconds dyff may take
M.TIMEOUT = 30 * 1000
--- Bytes of a comparison kept
M.MAX_OUTPUT = 1024 * 1024

--- The extensions of the documents dyff reads
M.STRUCTURED = { yaml = true, yml = true, json = true, toml = true }

--- Whether dyff reads `file`
---@param file string
---@return boolean
function M.structured(file)
  return M.STRUCTURED[(file:match('%.([%w]+)$') or ''):lower()] == true
end

--- The bytes `a` and `b` start with in common
---@param a string
---@param b string
---@return integer
local function shared_prefix(a, b)
  local count = 0
  for index = 1, math.min(#a, #b) do
    if a:sub(index, index) ~= b:sub(index, index) then break end
    count = index
  end
  return count
end

--- The files beside `file` of its extension, the ones whose names share the
--- most with its own first: `values-prod.yaml` before `chart.yaml` for
--- `values-dev.yaml`
---@param file string
---@return string[]
function M.candidates(file)
  local dir, own = vim.fs.dirname(file), vim.fs.basename(file)
  local ext = own:match('(%.[^.]+)$')
  if not ext then return {} end
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    if
      (kind == 'file' or kind == 'link')
      and name ~= own
      and name:sub(-#ext) == ext
    then
      table.insert(found, name)
    end
  end
  table.sort(found, function(a, b)
    local x, y = shared_prefix(a, own), shared_prefix(b, own)
    if x ~= y then return x > y end
    return a < b
  end)
  return vim.tbl_map(
    function(name) return vim.fs.joinpath(dir, name) end,
    found
  )
end

--- The `dyff between` comparing `from` with `to`
---@param from string
---@param to string
---@return string[]
function M.command_for(from, to)
  return { 'dyff', 'between', '--omit-header', '--color=off', from, to }
end

--- Whether `file` holds what must not leave the machine
---@param file string
---@return boolean
local function sensitive(file)
  local sensitive_util = require('util.sensitive')
  local bufnr = vim.fn.bufnr(file)
  if bufnr ~= -1 and sensitive_util.is_sensitive(bufnr) then return true end
  return sensitive_util.is_sensitive_path(file)
end

--- A diff split of the current window against `other`
---@param other string
local function split(other)
  vim.cmd('vertical diffsplit ' .. vim.fn.fnameescape(other))
end

--- Compare the buffer's file with `other`
---@param other string
---@param on_done? fun() For the specs
function M.compare(other, on_done)
  local function finish(...)
    if select('#', ...) > 0 then notify(...) end
    if on_done then on_done() end
  end
  local file = vim.api.nvim_buf_get_name(0)
  other = vim.fn.fnamemodify(vim.fn.expand(other), ':p')
  if vim.fn.filereadable(file) ~= 1 then
    return finish('The buffer is no file on disk', vim.log.levels.WARN)
  end
  if vim.fn.filereadable(other) ~= 1 then
    return finish('No such file: ' .. other, vim.log.levels.ERROR)
  end
  if not (M.structured(file) and M.structured(other)) then
    split(other)
    return finish()
  end
  if vim.fn.executable('dyff') ~= 1 then
    split(other)
    return finish(
      'dyff is not installed: a line diff instead',
      vim.log.levels.WARN
    )
  end
  local modified = vim.bo.modified
    or (vim.fn.bufnr(other) ~= -1 and vim.bo[vim.fn.bufnr(other)].modified)
  require('util.system').run(
    M.command_for(file, other),
    { timeout = M.TIMEOUT, max_bytes = M.MAX_OUTPUT },
    function(result)
      if result.code ~= 0 then
        return finish(
          require('util.system').failure(result, 'dyff'),
          vim.log.levels.ERROR
        )
      end
      local lines =
        vim.split(vim.trim(result.stdout or ''), '\n', { plain = true })
      if #lines == 1 and lines[1] == '' then
        return finish(
          ('No differences%s'):format(
            modified and ' on disk; unsaved changes are not compared' or ''
          )
        )
      end
      local title = ('%s → %s'):format(
        vim.fn.fnamemodify(file, ':~:.'),
        vim.fn.fnamemodify(other, ':~:.')
      )
      local header = { '# ' .. title, '' }
      if modified then
        table.insert(header, 'As on disk: unsaved changes are not compared.')
        table.insert(header, '')
      end
      if result.cut then
        table.insert(lines, ('… cut at %d KiB'):format(M.MAX_OUTPUT / 1024))
      end
      require('util.scratch').open(vim.list_extend(header, lines), {
        split = 'vertical',
        filetype = 'yaml',
        sensitive = (sensitive(file) or sensitive(other))
            and 'compares the values of a sensitive file'
          or 'compares the values of two settings files',
      })
      finish()
    end
  )
end

--- `:DyEnvDiff [{other}]`, asking for the other file among those beside it
--- when not given
---@param args { fargs: string[] }
function M.command(args)
  if args.fargs[1] then return M.compare(args.fargs[1]) end
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    return notify('The buffer is no file on disk', vim.log.levels.WARN)
  end
  local candidates = M.candidates(file)
  if #candidates == 0 then
    return notify('No other file of this kind beside it: give one')
  end
  vim.ui.select(candidates, {
    prompt = 'Compare with',
    format_item = function(path) return vim.fs.basename(path) end,
  }, function(choice)
    if choice then M.compare(choice) end
  end)
end

return M
