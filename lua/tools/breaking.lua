--- What a Protobuf or GraphQL contract breaks of itself at a revision
---
--- The two contracts between services that OpenAPI and AsyncAPI do not
--- cover. `:DyBreaking [{rev}]` compares the buffer's schema with the one at
--- `HEAD` (or any revision) and lists each change that breaks a client in
--- the quickfix list: for Protobuf through `buf breaking`, which compares
--- the module's files as they are on disk against git; for GraphQL through
--- `graphql-inspector diff`, the schema files beside the buffer -- the
--- buffer as it is -- against the same directory at the revision. A run
--- that fails is said to, never taken for a clean result.
local M = {}

local notify = require('util.notify').titled('Breaking changes')

--- Milliseconds a comparison may take: buf clones the revision first
M.TIMEOUT = 90 * 1000

--- What a revision may be made of: it goes into buf's input string, where a
--- comma or a `#` would start another option
---@param rev string
---@return boolean
function M.safe_rev(rev) return rev:match('^[%w%._/%-~^@]+$') ~= nil end

---@class DyBreakingCmd
---@field cmd string[]
---@field cwd string
---@field module string The directory of the `buf.yaml`

--- The `buf breaking` run for `file` against `rev`: from the root of the
--- repository, on the directory of its `buf.yaml`
---@param file string
---@param rev string
---@return DyBreakingCmd? run
---@return string? err
function M.buf_cmd(file, rev)
  local module = vim.fs.root(file, { 'buf.yaml', 'buf.work.yaml' })
  local repo = vim.fs.root(file, '.git')
  if not module then return nil, 'No buf.yaml above this file' end
  if not repo then return nil, 'This file is not in a git repository' end
  local subdir = vim.fs.relpath(repo, module) or '.'
  local against = '.git#ref=' .. rev
  if subdir ~= '.' then against = against .. ',subdir=' .. subdir end
  return {
    cmd = {
      'buf',
      'breaking',
      subdir,
      '--against',
      against,
      '--error-format',
      'json',
    },
    cwd = repo,
    module = module,
  }
end

--- The quickfix items of `buf breaking --error-format json`, a JSON object
--- a line; nil when a line is not one. A finding with no path (a file
--- deleted) is put on `fallback`.
---@param text string
---@param cwd string What the paths are relative to
---@param fallback? string
---@return vim.quickfix.entry[]?
function M.buf_items(text, cwd, fallback)
  local items = {}
  for line in vim.gsplit(text, '\n', { plain = true }) do
    if line:match('%S') then
      local ok, annotation = pcall(vim.json.decode, line)
      if not ok or type(annotation) ~= 'table' then return nil end
      table.insert(items, {
        filename = annotation.path and vim.fs.joinpath(cwd, annotation.path)
          or fallback,
        lnum = annotation.start_line or 1,
        col = annotation.start_column or 1,
        type = 'E',
        text = ('%s [%s]'):format(
          annotation.message or 'breaking change',
          annotation.type or '?'
        ),
      })
    end
  end
  return items
end

--- The breaking changes `graphql-inspector diff` printed: its `✖` lines,
--- without colour or the `[log]` it puts before them off a terminal
---@param text string
---@return string[]
function M.inspector_changes(text)
  local changes = {}
  for line in vim.gsplit(text, '\n', { plain = true }) do
    line = line:gsub('\27%[[%d;]*m', '')
    local message = line:match('✖%s+(.-)%s*$')
    if message and message ~= '' then table.insert(changes, message) end
  end
  return changes
end

--- The keywords that start the definition of a GraphQL type
local DEFINITIONS = {
  type = true,
  input = true,
  interface = true,
  enum = true,
  union = true,
  scalar = true,
}

--- The line of `lines` a change is about: the field of `Type.field` inside
--- its type, else the type; nil when the type is not there
---@param lines string[]
---@param message string
---@return integer?
local function find_line(lines, message)
  local type_name, field = message:match('(%u[%w_]*)%.([%w_]+)')
  if not type_name then
    -- `Type User was removed`, `Enum value ... on enum Role`: the last name
    for name in message:gmatch('(%u[%w_]*)') do
      type_name = name
    end
  end
  if not type_name then return nil end
  local start
  for number, line in ipairs(lines) do
    local keyword, name = line:match('^%s*(%a+)%s+([%w_]+)')
    if name == type_name and DEFINITIONS[keyword] then
      start = number
      break
    end
  end
  if not start then return nil end
  if field then
    for number = start + 1, #lines do
      if lines[number]:match('^}') then break end
      if lines[number]:match('^%s*' .. field .. '%s*[(:]') then
        return number
      end
    end
  end
  return start
end

--- Where among `files` a change is about: the first that defines its type,
--- else line 1 of `default`
---@param files table<string, string[]> Lines by path
---@param default string
---@param message string
---@return string file
---@return integer lnum
function M.graphql_locate(files, default, message)
  local paths = vim.tbl_keys(files)
  table.sort(paths)
  table.insert(paths, 1, default)
  for _, path in ipairs(paths) do
    local lnum = files[path] and find_line(files[path], message)
    if lnum then return path, lnum end
  end
  return default, 1
end

--- Whether `name` is a GraphQL schema file
---@param name string
---@return boolean
local function is_schema(name)
  return name:match('%.graphqls?$') ~= nil or name:match('%.gql$') ~= nil
end

--- The files of `git cat-file --batch`, in the order asked; nil when one is
--- missing or the output cannot be read
---@param out string
---@return string[]?
function M.batch_files(out)
  local files, pos = {}, 1
  while pos <= #out do
    local eol = out:find('\n', pos, true)
    if not eol then return nil end
    local size = tonumber(out:sub(pos, eol - 1):match('^%x+ blob (%d+)$'))
    if not size then return nil end
    table.insert(files, out:sub(eol + 1, eol + size))
    pos = eol + size + 2
  end
  return files
end

--- The canonical form of `path`, symlinks resolved when it exists
---@param path string
---@return string
local function real(path)
  return vim.fs.normalize(vim.uv.fs_realpath(path) or path)
end

--- A modified buffer whose file is under `dir`, if any
---@param dir string
---@return string?
local function modified_under(dir)
  dir = real(dir)
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      name ~= ''
      and vim.api.nvim_buf_is_loaded(bufnr)
      and vim.bo[bufnr].modified
      and vim.fs.relpath(dir, real(name))
    then
      return name
    end
  end
end

--- Hand the outcome of a comparison to the quickfix list, or say there is
--- none
---@param items vim.quickfix.entry[]
---@param rev string
---@param tool string
local function show(items, rev, tool)
  if #items == 0 then
    return notify(('Nothing breaks since %s (%s)'):format(rev, tool))
  end
  vim.fn.setqflist({}, ' ', {
    title = ('Breaking changes since %s'):format(rev),
    items = items,
  })
  vim.cmd('botright copen')
  notify(
    ('%d breaking changes since %s (%s)'):format(#items, rev, tool),
    vim.log.levels.WARN
  )
end

--- Compare the Protobuf module of `bufnr` with itself at `rev`
---@param bufnr integer
---@param rev string
local function protobuf(bufnr, rev)
  local file = vim.api.nvim_buf_get_name(bufnr)
  local run, err = M.buf_cmd(file, rev)
  if not run then return notify(err, vim.log.levels.WARN) end
  local unsaved = modified_under(run.module)
  if unsaved then
    return notify(
      ('Write %s first: buf compares the files on disk'):format(
        vim.fn.fnamemodify(unsaved, ':~:.')
      ),
      vim.log.levels.WARN
    )
  end
  -- buf runs the check plugins its config lists, at both revisions
  local question = ('Run buf breaking in %s?\nIt runs the plugins its buf.yaml lists as you.'):format(
    vim.fn.fnamemodify(run.module, ':~')
  )
  if not require('util.trust').ask('buf', run.module, question) then
    return notify(
      'Not run: the module is not trusted to run its plugins',
      vim.log.levels.WARN
    )
  end
  local system = require('util.system')
  system.run(run.cmd, { cwd = run.cwd, timeout = M.TIMEOUT }, function(result)
    -- 100 is buf's exit when a rule breaks; any other but 0 is a failure
    local items = (result.code == 0 or result.code == 100)
      and not result.cut
      and M.buf_items(result.stdout or '', run.cwd, file)
    if not items or (result.code == 100 and #items == 0) then
      return notify(
        'buf breaking failed: ' .. system.failure(result, 'buf'),
        vim.log.levels.ERROR
      )
    end
    show(items, rev, 'buf')
  end)
end

--- The schema files of `dir` as they are: on disk, or in their buffer
--- when loaded, written or not
---@param dir string
---@param bufnr integer Taken even when its file is not written yet
---@return table<string, string[]> Lines by path
local function current_schema(dir, bufnr)
  local files = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' and is_schema(name) then
      local path = vim.fs.joinpath(dir, name)
      local ok, lines = pcall(vim.fn.readfile, path)
      files[path] = ok and lines or {}
    end
  end
  for _, other in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(other)
    if
      vim.api.nvim_buf_is_loaded(other)
      and (other == bufnr or files[name])
    then
      files[name] = vim.api.nvim_buf_get_lines(other, 0, -1, false)
    end
  end
  return files
end

--- Compare the GraphQL schema of `bufnr` -- every schema file beside it, the
--- buffer as it is -- with the same directory at `rev`
---@param bufnr integer
---@param rev string
local function graphql(bufnr, rev)
  if vim.fn.executable('graphql-inspector') ~= 1 then
    return notify(
      'graphql-inspector is not installed: `:MasonInstall graphql-inspector`',
      vim.log.levels.ERROR
    )
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  local dir = vim.fs.dirname(file)
  local system = require('util.system')
  local function missing()
    notify(
      ('No schema beside %s in git at %s'):format(vim.fs.basename(file), rev),
      vim.log.levels.WARN
    )
  end
  -- Only this directory: a schema split over files keeps them side by side,
  -- and a type moved between them is not a removal
  system.run(
    { 'git', 'ls-tree', '-z', '--full-name', '--name-only', rev, '--', '.' },
    { cwd = dir, timeout = 10000 },
    function(listed)
      if listed.code ~= 0 or listed.cut then return missing() end
      local paths = vim.tbl_filter(
        function(path) return is_schema(path) and not path:find('\n') end,
        vim.split(listed.stdout, '\0', { plain = true, trimempty = true })
      )
      if #paths == 0 then return missing() end
      local wanted = vim.tbl_map(
        function(path) return ('%s:%s\n'):format(rev, path) end,
        paths
      )
      system.run({ 'git', 'cat-file', '--batch' }, {
        cwd = dir,
        timeout = 10000,
        stdin = table.concat(wanted),
        text = false,
      }, function(old)
        local blobs = old.code == 0
          and not old.cut
          and M.batch_files(old.stdout or '')
        if not blobs or #blobs ~= #paths then return missing() end
        local current = current_schema(dir, bufnr)
        local tmp = vim.fn.tempname()
        -- `.graphql` appended, so one pattern reads `.gql` files too
        for index, path in ipairs(paths) do
          local name = ('%s/old/%d-%s.graphql'):format(
            tmp,
            index,
            vim.fs.basename(path)
          )
          vim.fn.mkdir(vim.fs.dirname(name), 'p')
          vim.fn.writefile(
            vim.split(blobs[index], '\n', { plain = true }),
            name,
            'b'
          )
        end
        vim.fn.mkdir(tmp .. '/new', 'p')
        local index = 0
        for path, lines in pairs(current) do
          index = index + 1
          vim.fn.writefile(
            lines,
            ('%s/new/%d-%s.graphql'):format(tmp, index, vim.fs.basename(path))
          )
        end
        system.run({
          'graphql-inspector',
          'diff',
          tmp .. '/old/*.graphql',
          tmp .. '/new/*.graphql',
        }, {
          timeout = M.TIMEOUT,
          env = { NO_COLOR = '1', FORCE_COLOR = '0' },
        }, function(result)
          vim.fn.delete(tmp, 'rf')
          local changes = M.inspector_changes(result.stdout or '')
          -- It exits 1 on a breaking change; with none to show, 1 is a
          -- failure
          if
            result.cut
            or (result.code ~= 0 and #changes == 0)
            or (result.code ~= 0 and result.code ~= 1)
          then
            return notify(
              'graphql-inspector failed: '
                .. system.failure(result, 'graphql-inspector'),
              vim.log.levels.ERROR
            )
          end
          show(
            vim.tbl_map(function(message)
              local path, lnum = M.graphql_locate(current, file, message)
              return {
                filename = path,
                lnum = lnum,
                type = 'E',
                text = message,
              }
            end, changes),
            rev,
            'graphql-inspector'
          )
        end)
      end)
    end
  )
end

--- Compare the contract of `bufnr` with itself at `rev`
---@param bufnr? integer
---@param rev? string `HEAD` unless given
function M.diff(bufnr, rev)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  rev = rev or 'HEAD'
  if not M.safe_rev(rev) then
    return notify('Not a revision: ' .. rev, vim.log.levels.ERROR)
  end
  if vim.api.nvim_buf_get_name(bufnr) == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  local filetype = vim.bo[bufnr].filetype
  if filetype == 'proto' then return protobuf(bufnr, rev) end
  if filetype == 'graphql' then return graphql(bufnr, rev) end
  notify(
    'Not a Protobuf or GraphQL file: `:DyOpenApiDiff` and `:DyAsyncApiDiff` compare the others',
    vim.log.levels.WARN
  )
end

--- The mapping of a Protobuf or GraphQL buffer
---@param bufnr integer
function M.attach(bufnr)
  vim.keymap.set(
    'n',
    '<localleader>d',
    function() M.diff(bufnr) end,
    { buffer = bufnr, desc = 'Breaking Changes Since HEAD' }
  )
end

return M
