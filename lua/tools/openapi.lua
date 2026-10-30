--- A request for the OpenAPI operation under the cursor, ready to send
---
--- In an OpenAPI document, the operation the cursor is in -- a method under
--- a path -- becomes a request for kulala (`.http`) or Hurl: the first
--- server as `baseUrl`, each path, query and header parameter as a variable
--- set to its example, and a JSON body made from the example or the schema
--- of the request. `$ref`s inside the document are followed; one to another
--- file is left as it is.
local M = {}

--- The copies `compare` wrote and has not removed yet, by path
---@type table<string, true>
M._leftover = {}

local METHODS = {
  get = true,
  put = true,
  post = true,
  delete = true,
  patch = true,
  head = true,
  options = true,
  trace = true,
}

--- A key at the start of a YAML or a pretty-printed JSON line, and its
--- indent: `  get:`, `"/pets/{id}": {`
---@param line string
---@return integer? indent
---@return string? key
local function key_of(line)
  local indent, key = line:match('^(%s*)"([^"]+)"%s*:%s*{?%s*$')
  if not key then
    indent, key = line:match("^(%s*)'([^']+)'%s*:%s*$")
  end
  if not key then
    indent, key = line:match('^(%s*)([^%s"\'#][^:]-)%s*:%s*$')
  end
  if not key then return nil end
  return #indent, key
end

---@class DyOpenApiOperation
---@field path string
---@field method? string Lower case; nil when the cursor is on the path

--- The operation `row` (1-based) is in, read off the keys that hold it: each
--- line above it indented less than every line since is one of them. The
--- first method among them is the operation, the first path its path.
---@param lines string[]
---@param row integer
---@return DyOpenApiOperation?
function M.operation_at(lines, row)
  local bound, method = math.huge, nil
  for number = math.min(row, #lines), 1, -1 do
    local line = lines[number]
    if line:match('%S') and not line:match('^%s*#') then
      local own = #line:match('^(%s*)')
      if own < bound then
        local _, key = key_of(line)
        -- The outermost one wins: a property of a body may well be called
        -- `options` or `delete`, the operation is the key right under the path
        if key and METHODS[key:lower()] then
          method = key:lower()
        elseif key and key:sub(1, 1) == '/' then
          return { path = key, method = method }
        end
        if own == 0 then return nil end
        bound = own
      end
    end
  end
  return nil
end

--- The node a local `$ref` points at, or nil
---@param doc table
---@param ref string
---@return any
local function pointer(doc, ref)
  if type(ref) ~= 'string' or not ref:match('^#/') then return nil end
  local node = doc
  for part in ref:sub(3):gmatch('[^/]+') do
    part = part:gsub('~1', '/'):gsub('~0', '~')
    if type(node) ~= 'table' then return nil end
    node = node[part]
  end
  return node
end

--- `node` with its `$ref` followed, as far as the document goes
---@param doc table
---@param node any
---@param depth? integer
---@return any
function M.resolve(doc, node, depth)
  depth = depth or 0
  if type(node) ~= 'table' or not node['$ref'] or depth > 16 then
    return node
  end
  local target = pointer(doc, node['$ref'])
  if target == nil then return node end
  return M.resolve(doc, target, depth + 1)
end

--- Placeholders for strings of a known format
local FORMATS = {
  ['date-time'] = '2026-01-01T00:00:00Z',
  date = '2026-01-01',
  email = 'user@example.com',
  uuid = '00000000-0000-0000-0000-000000000000',
  uri = 'https://example.com',
  hostname = 'example.com',
  ipv4 = '192.0.2.1',
}

--- An example value of `schema`: its own example, default or first enum
--- value, else one built from its type
---@param doc table
---@param schema any
---@param depth? integer
---@return any
function M.example(doc, schema, depth)
  depth = depth or 0
  schema = M.resolve(doc, schema)
  if type(schema) ~= 'table' or depth > 8 then return vim.NIL end
  if schema.example ~= nil then return schema.example end
  if type(schema.examples) == 'table' and schema.examples[1] ~= nil then
    return schema.examples[1]
  end
  if schema.default ~= nil then return schema.default end
  if type(schema.enum) == 'table' and schema.enum[1] ~= nil then
    return schema.enum[1]
  end
  for _, key in ipairs({ 'oneOf', 'anyOf' }) do
    if type(schema[key]) == 'table' and schema[key][1] then
      return M.example(doc, schema[key][1], depth + 1)
    end
  end
  if type(schema.allOf) == 'table' then
    local merged = vim.empty_dict()
    for _, part in ipairs(schema.allOf) do
      local value = M.example(doc, part, depth + 1)
      if type(value) == 'table' and not vim.islist(value) then
        for key, item in pairs(value) do
          merged[key] = item
        end
      end
    end
    return merged
  end
  local kind = schema.type
  if type(kind) == 'table' then kind = kind[1] end
  if
    kind == 'object' or (kind == nil and type(schema.properties) == 'table')
  then
    local object = vim.empty_dict()
    for key, property in pairs(schema.properties or {}) do
      object[key] = M.example(doc, property, depth + 1)
    end
    return object
  end
  if kind == 'array' then return { M.example(doc, schema.items, depth + 1) } end
  if kind == 'integer' or kind == 'number' then return 0 end
  if kind == 'boolean' then return false end
  if kind == 'string' then return FORMATS[schema.format] or 'string' end
  return vim.NIL
end

---@class DyOpenApiParam
---@field name string
---@field value string Its example, as text

---@class DyOpenApiRequest
---@field name string
---@field method string Upper case
---@field base string The URL of the first server, or a placeholder
---@field path string With `{{name}}` for each path parameter
---@field vars DyOpenApiParam[] Path parameters
---@field query DyOpenApiParam[]
---@field headers DyOpenApiParam[]
---@field body? string JSON
---@field content_type? string

--- A value as the text of a variable
---@param value any
---@return string
local function text(value)
  if value == nil or value == vim.NIL then return '' end
  if type(value) == 'table' then return vim.json.encode(value) end
  return tostring(value)
end

--- `value` as indented JSON, keys sorted
---@param value any
---@return string
local function pretty(value)
  local ok, json =
    pcall(vim.json.encode, value, { indent = '  ', sort_keys = true })
  return ok and json or vim.json.encode(value)
end

--- The request of `op` in `doc`
---@param doc table
---@param op DyOpenApiOperation
---@return DyOpenApiRequest? request
---@return string? err
function M.request(doc, op)
  local item = M.resolve(doc, vim.tbl_get(doc, 'paths', op.path))
  if type(item) ~= 'table' then return nil, 'No path ' .. op.path end
  local method = op.method
  if not method then
    for _, candidate in ipairs({ 'get', 'post', 'put', 'patch', 'delete' }) do
      if item[candidate] then
        method = candidate
        break
      end
    end
  end
  local operation = method and M.resolve(doc, item[method])
  if type(operation) ~= 'table' then
    return nil, ('No operation under %s'):format(op.path)
  end

  local request = {
    name = operation.operationId or (method:upper() .. ' ' .. op.path),
    method = method:upper(),
    base = text(vim.tbl_get(doc, 'servers', 1, 'url')),
    path = op.path,
    vars = {},
    query = {},
    headers = {},
  }
  if request.base == '' then request.base = 'http://localhost' end
  request.base = request.base:gsub('/$', '')

  -- The operation's parameters override the path's of the same name
  local params, seen = {}, {}
  for _, list in ipairs({ operation.parameters or {}, item.parameters or {} }) do
    for _, param in ipairs(list) do
      param = M.resolve(doc, param)
      if type(param) == 'table' and param.name and param['in'] then
        local key = param['in'] .. ':' .. param.name
        if not seen[key] then
          seen[key] = true
          table.insert(params, param)
        end
      end
    end
  end
  for _, param in ipairs(params) do
    local value = param.example
    if value == nil then value = M.example(doc, param.schema) end
    -- A variable is one line of the file: a multi-line example keeps its
    -- breaks as `\n`
    local entry = {
      name = param.name,
      value = (text(value):gsub('\r?\n', '\\n')),
    }
    if param['in'] == 'path' then
      table.insert(request.vars, entry)
    elseif param['in'] == 'query' then
      table.insert(request.query, entry)
    elseif param['in'] == 'header' then
      table.insert(request.headers, entry)
    end
  end
  request.path = request.path:gsub('{([^}]+)}', '{{%1}}')

  local content =
    vim.tbl_get(M.resolve(doc, operation.requestBody) or {}, 'content')
  if type(content) == 'table' then
    local media = content['application/json'] and 'application/json'
      or next(content)
    local body = media and content[media]
    if type(body) == 'table' then
      local value = body.example
      if value == nil and type(body.examples) == 'table' then
        local _, first = next(body.examples)
        value = type(first) == 'table' and M.resolve(doc, first).value
      end
      if value == nil then value = M.example(doc, body.schema) end
      request.content_type = media
      if value ~= vim.NIL and value ~= nil then
        request.body = media:match('json') and pretty(value) or text(value)
      end
    end
  end
  return request
end

--- The query string of `request`, its values as variables
---@param request DyOpenApiRequest
---@return string
local function query_string(request)
  local parts = {}
  for _, param in ipairs(request.query) do
    table.insert(parts, ('%s={{%s}}'):format(param.name, param.name))
  end
  return #parts > 0 and ('?' .. table.concat(parts, '&')) or ''
end

--- `request` for kulala, as the lines of a `.http` file
---@param request DyOpenApiRequest
---@return string[]
function M.http(request)
  local lines = { '@baseUrl = ' .. request.base }
  for _, list in ipairs({ request.vars, request.query, request.headers }) do
    for _, param in ipairs(list) do
      table.insert(lines, ('@%s = %s'):format(param.name, param.value))
    end
  end
  vim.list_extend(lines, {
    '',
    '### ' .. request.name,
    ('%s {{baseUrl}}%s%s'):format(
      request.method,
      request.path,
      query_string(request)
    ),
  })
  for _, header in ipairs(request.headers) do
    table.insert(lines, ('%s: {{%s}}'):format(header.name, header.name))
  end
  if request.body then
    table.insert(lines, 'Content-Type: ' .. request.content_type)
    table.insert(lines, '')
    vim.list_extend(lines, vim.split(request.body, '\n', { plain = true }))
  end
  return lines
end

--- `word` as one word of a shell command line, quoted only when it has to be
---@param word string
---@return string
local function shell_word(word)
  if word:match('^[%w%._/:=@,+%-]+$') then return word end
  return vim.fn.shellescape(word)
end

--- `request` for Hurl, the variables to pass said on its first line, ready
--- to paste into a shell
---@param request DyOpenApiRequest
---@return string[]
function M.hurl(request)
  local vars = { '--variable ' .. shell_word('baseUrl=' .. request.base) }
  for _, list in ipairs({ request.vars, request.query, request.headers }) do
    for _, param in ipairs(list) do
      table.insert(
        vars,
        '--variable ' .. shell_word(param.name .. '=' .. param.value)
      )
    end
  end
  local lines = {
    '# ' .. request.name,
    '# hurl ' .. table.concat(vars, ' '),
    ('%s {{baseUrl}}%s'):format(request.method, request.path),
  }
  for _, header in ipairs(request.headers) do
    table.insert(lines, ('%s: {{%s}}'):format(header.name, header.name))
  end
  if request.body and request.content_type then
    table.insert(lines, 'Content-Type: ' .. request.content_type)
  end
  if #request.query > 0 then
    table.insert(lines, '[QueryStringParams]')
    for _, param in ipairs(request.query) do
      table.insert(lines, ('%s: {{%s}}'):format(param.name, param.name))
    end
  end
  if request.body then
    vim.list_extend(lines, vim.split(request.body, '\n', { plain = true }))
  end
  return lines
end

local notify = require('util.notify').titled('OpenAPI')

--- Hand `on_doc` the document of `bufnr`, decoded: JSON as it is, YAML
--- through `yq` off the main loop
---@param bufnr integer
---@param on_doc fun(doc: table?, err: string?)
function M.decode(bufnr, on_doc)
  local source =
    table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
  local function decode(json)
    local ok, doc =
      pcall(vim.json.decode, json, { luanil = { object = true, array = true } })
    if not ok or type(doc) ~= 'table' then
      return on_doc(nil, 'Not a JSON document')
    end
    on_doc(doc)
  end
  if vim.bo[bufnr].filetype:match('^json') then return decode(source) end
  if vim.fn.executable('yq') ~= 1 then
    return on_doc(nil, 'yq is needed to read an OpenAPI document in YAML')
  end
  local system = require('util.system')
  system.run(
    { 'yq', '-o=json', '.' },
    { stdin = source, timeout = 10000 },
    function(result)
      if result.code ~= 0 or result.cut then
        return on_doc(
          nil,
          'yq could not read it: '
            .. (
              result.cut and 'more output than can be read'
              or system.failure(result, 'yq')
            )
        )
      end
      decode(result.stdout or '')
    end
  )
end

--- Open the request of the operation under the cursor, for `kind`
---@param kind 'http'|'hurl'
function M.open(kind)
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local op =
    M.operation_at(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), row)
  if not op then
    return notify('The cursor is in no operation', vim.log.levels.WARN)
  end
  M.decode(bufnr, function(doc, err)
    if not doc then return notify(err, vim.log.levels.ERROR) end
    local request, why = M.request(doc, op)
    if not request then return notify(why, vim.log.levels.WARN) end

    vim.cmd('botright new')
    local out = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(
      out,
      0,
      -1,
      false,
      kind == 'hurl' and M.hurl(request) or M.http(request)
    )
    vim.bo[out].filetype = kind
    vim.bo[out].modified = false
  end)
end

--- `:DyOpenApiRequest [http|hurl]`
---@param args { fargs: string[] }
function M.command(args)
  local kind = args.fargs[1] or 'http'
  if kind ~= 'http' and kind ~= 'hurl' then
    return notify('Unknown kind: ' .. kind, vim.log.levels.ERROR)
  end
  M.open(kind)
end

--- The mappings of an OpenAPI document
---@param bufnr integer
function M.attach(bufnr)
  vim.keymap.set(
    'n',
    '<localleader>h',
    function() M.open('http') end,
    { buffer = bufnr, desc = 'Request For kulala (OpenAPI)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>H',
    function() M.open('hurl') end,
    { buffer = bufnr, desc = 'Request For Hurl (OpenAPI)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>d',
    function() M.diff(bufnr) end,
    { buffer = bufnr, desc = 'Breaking Changes Since HEAD (OpenAPI)' }
  )
end

--- Where the operation `method` of `path` is defined, 1-based: the method
--- key inside the path's block, else the path key, else nil
---@param lines string[]
---@param path? string
---@param method? string
---@return integer?
function M.line_of(lines, path, method)
  if not path then return nil end
  local path_line, path_indent
  for number, line in ipairs(lines) do
    local indent, key = key_of(line)
    if path_line then
      local own = #line:match('^(%s*)')
      if line:match('%S') and own <= path_indent then break end
      if key and method and key:lower() == method:lower() then return number end
    elseif key == path then
      path_line, path_indent = number, indent
    end
  end
  return path_line
end

local diff_ns = vim.api.nvim_create_namespace('dy_openapi_diff')

--- How loud each level of oasdiff is: 3 breaks clients, 2 may, 1 is news
local LEVELS = {
  [3] = vim.diagnostic.severity.ERROR,
  [2] = vim.diagnostic.severity.WARN,
  [1] = vim.diagnostic.severity.INFO,
}

--- Diagnostics of the changes `oasdiff breaking --format json` reported,
--- each on the operation it is about
---@param changes table[]
---@param lines string[]
---@return vim.Diagnostic[]
function M.diff_diagnostics(changes, lines)
  local diagnostics = {}
  for _, change in ipairs(changes) do
    if type(change) == 'table' then
      local line = M.line_of(lines, change.path, change.operation) or 1
      table.insert(diagnostics, {
        lnum = line - 1,
        col = 0,
        severity = LEVELS[tonumber(change.level)]
          or vim.diagnostic.severity.WARN,
        message = change.text or change.id or 'changed',
        code = change.id,
        source = 'oasdiff',
      })
    end
  end
  return diagnostics
end

--- Show what the buffer, as it is now, breaks of the spec at `rev`
---@param bufnr? integer
---@param rev? string `HEAD` unless given
function M.diff(bufnr, rev)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  rev = rev or 'HEAD'
  if vim.fn.executable('oasdiff') ~= 1 then
    return notify('oasdiff is not installed', vim.log.levels.ERROR)
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  -- The buffer as it is now: what is compared, however long the lookup takes
  local current = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local modified = vim.bo[bufnr].modified
  require('util.system').run(
    { 'git', 'show', ('%s:./%s'):format(rev, name) },
    { cwd = dir, timeout = 10000 },
    function(old)
      if old.missing then
        return notify('git could not run', vim.log.levels.ERROR)
      end
      if old.code ~= 0 or old.cut then
        return notify(
          ('%s is not in git at %s'):format(name, rev),
          vim.log.levels.WARN
        )
      end
      M.compare(bufnr, rev, file, old.stdout or '', current, modified)
    end
  )
end

--- Compare `base_text`, the document at `rev`, with `current`, and show what
--- breaks on `bufnr`
---@param bufnr integer
---@param rev string
---@param file string
---@param base_text string
---@param current string[]
---@param modified boolean Whether `current` differs from the file
function M.compare(bufnr, rev, file, base_text, current, modified)
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  -- Beside the document, under hidden names that keep its extension, so a
  -- relative `$ref` resolves from either side; the file itself stands for
  -- the buffer when they agree
  local base = vim.fs.joinpath(dir, '.oasdiff-base-' .. name)
  local revision = modified
      and vim.fs.joinpath(dir, '.oasdiff-revision-' .. name)
    or file
  for _, path in ipairs({ base, revision ~= file and revision or nil }) do
    -- The link itself: a dangling one would be written through, to wherever
    -- the repository points it
    if vim.uv.fs_lstat(path) then
      return notify(
        ('%s is in the way: not written over'):format(vim.fs.basename(path)),
        vim.log.levels.ERROR
      )
    end
  end
  local written = { base }
  vim.fn.writefile(vim.split(base_text, '\n', { plain = true }), base)
  if modified then
    table.insert(written, revision)
    vim.fn.writefile(current, revision)
  end
  -- Gone however the run ends: with it, when it cannot start, or with Neovim
  local function remove()
    for _, path in ipairs(written) do
      vim.fn.delete(path)
      M._leftover[path] = nil
    end
  end
  for _, path in ipairs(written) do
    M._leftover[path] = true
  end
  -- A group of its own: `dy_openapi` holds the `FileType` hook of
  -- `plugin/openapi.lua`, which clearing it would remove
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = vim.api.nvim_create_augroup(
      'dy_openapi_leftover',
      { clear = true }
    ),
    callback = function()
      for path in pairs(M._leftover) do
        vim.fn.delete(path)
      end
    end,
  })
  local system = require('util.system')
  local started = system.run(
    { 'oasdiff', 'breaking', base, revision, '--format', 'json' },
    { timeout = 60000 },
    function(result)
      remove()
      if result.missing or not vim.api.nvim_buf_is_valid(bufnr) then return end
      -- A failed run says nothing about breaking: never an all-clear
      if result.code ~= 0 or result.cut then
        return notify(
          'oasdiff failed: '
            .. (
              result.cut and 'more output than can be read'
              or system.failure(result, 'oasdiff')
            ),
          vim.log.levels.ERROR
        )
      end
      local ok, changes = pcall(
        vim.json.decode,
        result.stdout ~= '' and result.stdout or '[]',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(changes) ~= 'table' then
        return notify(
          'oasdiff printed something that is not JSON',
          vim.log.levels.ERROR
        )
      end
      local diagnostics = M.diff_diagnostics(
        changes,
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
      vim.diagnostic.set(diff_ns, bufnr, diagnostics)
      notify(
        #diagnostics == 0 and ('Nothing breaks since %s'):format(rev)
          or ('%d changes since %s'):format(#diagnostics, rev),
        #diagnostics > 0 and vim.log.levels.WARN or nil
      )
    end
  )
  if not started then
    remove()
    notify('oasdiff could not run', vim.log.levels.ERROR)
  end
end

return M
