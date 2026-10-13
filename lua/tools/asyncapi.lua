--- What an AsyncAPI document breaks of itself at a revision
---
--- The schema comes from SchemaStore through yamlls and jsonls, for files
--- named `*asyncapi*`; this adds what a schema cannot say: which change to
--- the channels, messages and payloads breaks a consumer. `:DyAsyncApiDiff`
--- compares the buffer, written or not, with the document at `HEAD` (or any
--- revision) through `asyncapi diff`, and shows each breaking change as an
--- error on the key it is about.
local M = {}

local notify = require('util.notify').titled('AsyncAPI')

--- The copies `diff` wrote and has not removed yet, by path
---@type table<string, true>
M._leftover = {}

--- The copies written and not removed yet, each with the process that
--- wrote it, kept across sessions: a copy a crashed session left is then
--- known as ours and removed, and a file of the same name that is not
--- stays untouched
M.STATE = vim.fs.joinpath(vim.fn.stdpath('state'), 'dy_asyncapi_copies.json')

--- The copies `M.STATE` lists, by path
---@return table<string, integer>
local function read_state()
  local ok, lines = pcall(vim.fn.readfile, M.STATE)
  if not ok then return {} end
  local decoded, state = pcall(vim.json.decode, table.concat(lines, '\n'))
  return decoded and type(state) == 'table' and state or {}
end

--- Record `paths` in `M.STATE` as written by `pid`, or as removed when nil
---@param paths string[]
---@param pid? integer
local function record(paths, pid)
  local state = read_state()
  for _, path in ipairs(paths) do
    state[path] = pid
  end
  vim.fn.mkdir(vim.fs.dirname(M.STATE), 'p')
  vim.fn.writefile({ vim.json.encode(state) }, M.STATE)
end

--- Whether process `pid` has ended
---@param pid integer
---@return boolean
local function ended(pid)
  local ok, _, name = vim.uv.kill(pid, 0)
  return ok == nil and name == 'ESRCH'
end

--- Lines read to find the `asyncapi:` key of a document
M.HEAD_LINES = 20

local ns = vim.api.nvim_create_namespace('dy_asyncapi_diff')

--- Whether `lines` start an AsyncAPI document
---@param lines string[]
---@return boolean
function M.is_document(lines)
  for i = 1, math.min(#lines, M.HEAD_LINES) do
    if
      lines[i]:match('^asyncapi%s*:') or lines[i]:match('^%s*"asyncapi"%s*:')
    then
      return true
    end
  end
  return false
end

--- A key at the start of a YAML or pretty-printed JSON line, and its indent
---@param line string
---@return integer? indent
---@return string? key
local function key_of(line)
  local indent, key = line:match('^(%s*)"([^"]+)"%s*:')
  if not key then
    indent, key = line:match("^(%s*)'([^']+)'%s*:")
  end
  if not key then
    indent, key = line:match('^(%s*)([^%s"\'#%-][^:]-)%s*:')
  end
  if not key then return nil end
  return #indent, key
end

--- The line (1-based) of the deepest key of JSON pointer `pointer` that
--- `lines` hold, or 1
---@param lines string[]
---@param pointer string `/channels/userSignedUp/messages`
---@return integer
function M.line_of(lines, pointer)
  local found, from, parent = 1, 1, -1
  for part in pointer:gmatch('[^/]+') do
    part = part:gsub('~1', '/'):gsub('~0', '~')
    -- shortcut: an array index stays on its list's key; walk `- ` items if a
    -- finer line is wanted
    if not part:match('^%d+$') then
      local hit
      for number = from, #lines do
        local indent, key = key_of(lines[number])
        if indent and indent <= parent and number > from then break end
        if key == part and indent > parent then
          hit = number
          parent = indent
          break
        end
      end
      if not hit then return found end
      found, from = hit, hit + 1
    end
  end
  return found
end

--- Diagnostics of the changes `asyncapi diff -f json` printed: a bare list,
--- or one under `changes`
---@param changes table
---@param lines string[]
---@return vim.Diagnostic[]
function M.diagnostics(changes, lines)
  if type(changes.changes) == 'table' then changes = changes.changes end
  local diagnostics = {}
  for _, change in ipairs(changes) do
    if type(change) == 'table' and type(change.path) == 'string' then
      local breaking = change.type == nil or change.type == 'breaking'
      table.insert(diagnostics, {
        lnum = M.line_of(lines, change.path) - 1,
        col = 0,
        severity = breaking and vim.diagnostic.severity.ERROR
          or vim.diagnostic.severity.INFO,
        message = ('%s %s'):format(change.action or 'changed', change.path),
        source = 'asyncapi',
      })
    end
  end
  return diagnostics
end

--- Show what the buffer, as it is now, breaks of the document at `rev`
---@param bufnr? integer
---@param rev? string `HEAD` unless given
function M.diff(bufnr, rev)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  rev = rev or 'HEAD'
  if vim.fn.executable('asyncapi') ~= 1 then
    return notify(
      'asyncapi is not installed: `:MasonInstall asyncapi-cli`',
      vim.log.levels.ERROR
    )
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local system = require('util.system')
  system.run(
    { 'git', 'show', ('%s:./%s'):format(rev, name) },
    { cwd = dir, timeout = 10000 },
    function(old)
      if old.code ~= 0 or old.cut then
        return notify(
          ('%s is not in git at %s'):format(name, rev),
          vim.log.levels.WARN
        )
      end
      -- Beside the document under hidden names that keep its extension, so
      -- a relative `$ref` resolves from either side
      local base = vim.fs.joinpath(dir, '.asyncapi-base-' .. name)
      local revision = vim.fs.joinpath(dir, '.asyncapi-revision-' .. name)
      local pid, state = vim.uv.os_getpid(), read_state()
      for _, path in ipairs({ base, revision }) do
        if vim.uv.fs_stat(path) then
          local owner = tonumber(state[path])
          if owner and owner ~= pid and ended(owner) then
            vim.fn.delete(path)
          else
            return notify(
              ('%s is in the way: not written over'):format(
                vim.fs.basename(path)
              ),
              vim.log.levels.ERROR
            )
          end
        end
      end
      record({ base, revision }, pid)
      vim.fn.writefile(vim.split(old.stdout, '\n', { plain = true }), base)
      vim.fn.writefile(current, revision)
      M._leftover[base], M._leftover[revision] = true, true
      vim.api.nvim_create_autocmd('VimLeavePre', {
        group = vim.api.nvim_create_augroup('dy_asyncapi', { clear = true }),
        callback = function()
          for path in pairs(M._leftover) do
            vim.fn.delete(path)
          end
          record(vim.tbl_keys(M._leftover))
        end,
      })
      local function remove()
        for _, path in ipairs({ base, revision }) do
          vim.fn.delete(path)
          M._leftover[path] = nil
        end
        record({ base, revision })
      end
      system.run({
        'asyncapi',
        'diff',
        base,
        revision,
        '-f',
        'json',
        '-t',
        'breaking',
        '--no-error',
        '--no-log-diagnostics',
      }, {
        cwd = dir,
        timeout = 60000,
        -- Its npm build reports every command, with facts read from the
        -- document, to New Relic unless `CI` is `true`
        env = { CI = 'true' },
      }, function(result)
        remove()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        -- A failed run says nothing about breaking: never an all-clear
        local json = (result.stdout or ''):match('[%[{].*$')
        local ok, changes = pcall(
          vim.json.decode,
          json or '',
          { luanil = { object = true, array = true } }
        )
        if
          result.code ~= 0
          or result.cut
          or not ok
          or type(changes) ~= 'table'
        then
          return notify(
            'asyncapi diff failed: '
              .. (
                result.cut and 'more output than can be read'
                or system.failure(result, 'asyncapi')
              ),
            vim.log.levels.ERROR
          )
        end
        local diagnostics = M.diagnostics(changes, current)
        vim.diagnostic.set(ns, bufnr, diagnostics)
        notify(
          #diagnostics == 0 and ('Nothing breaks since %s'):format(rev)
            or ('%d breaking changes since %s'):format(#diagnostics, rev),
          #diagnostics > 0 and vim.log.levels.WARN or nil
        )
      end)
    end
  )
end

--- The mapping of an AsyncAPI document
---@param bufnr integer
function M.attach(bufnr)
  vim.keymap.set(
    'n',
    '<localleader>d',
    function() M.diff(bufnr) end,
    { buffer = bufnr, desc = 'Breaking Changes Since HEAD (AsyncAPI)' }
  )
end

return M
