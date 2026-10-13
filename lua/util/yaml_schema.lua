-- Schema detection and selection for yaml-language-server.
--
-- SchemaStore globs are handed to the server as schema associations, one
-- priority below `yaml.schemas`. That leaves `yaml.schemas` free for a schema
-- chosen for a single buffer, which then wins over whatever glob matched the
-- file instead of being merged with it through `allOf`.
--
-- On top of that, buffers the server finds no schema for are matched on their
-- content (Kubernetes manifests, cloud-init), and a picker sets a schema for
-- the buffer or writes it as a `# yaml-language-server: $schema=` modeline.
-- Besides the catalogs, it offers the schema files of the project and of
-- `DyNeo.yaml_schema_dirs`, and any other file of this machine by its path.
local M = {}

local CRDS_CATALOG =
  'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main'
local CRDS_TREE =
  'https://api.github.com/repos/datreeio/CRDs-catalog/git/trees/main?recursive=1'
local KUBERNETES_SCHEMAS =
  'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master'
local CLOUD_INIT =
  'https://raw.githubusercontent.com/canonical/cloud-init/main/cloudinit/config/schemas/schema-cloud-config-v1.json'
-- The URL SchemaStore lists it under, so the picker names it the same
local SIGMA =
  'https://raw.githubusercontent.com/SigmaHQ/sigma-specification/main/json-schema/sigma-detection-rule-schema.json'
-- The keyword yamlls expands into the schema of every built-in kind, and then
-- narrows down per document by `apiVersion`/`kind`, CRDs included
local KUBERNETES = 'kubernetes'
local CRDS_CACHE = vim.fn.stdpath('cache') .. '/yaml-schema/crds-catalog.json'
local CRDS_TTL = 7 * 24 * 60 * 60
local MODELINE = '# yaml-language-server: $schema='

--- Entries the search without `fd` looks at before it stops: a few hundred
--- milliseconds of the main loop, where a whole `$HOME` takes seconds
M.MAX_WALK = 10000

---@class util.yaml_schema.Schema
---@field uri string URL, path, or the `kubernetes` keyword
---@field name string
---@field description? string
---@field source string where the schema comes from, shown in the picker
---@field file_match? string[]

---@class util.yaml_schema.Choice
---@field uri string
---@field name string
---@field auto boolean set by content detection, not by the user
---@field pattern string glob added to `yaml.schemas[uri]` for this buffer

---@type string[]?
local crds
---@type table<string, string>? SchemaStore names by URL
local names

local function get_client(bufnr)
  return vim.lsp.get_clients({ bufnr = bufnr, name = 'yamlls' })[1]
end

--- Lines of the buffer, up to `max`
local function get_lines(bufnr, max)
  return vim.api.nvim_buf_get_lines(bufnr, 0, max or -1, false)
end

local function is_separator(line)
  return line:match('^%-%-%-') and (#line == 3 or line:sub(4, 4):match('%s'))
end

--- A path turned into a glob that only matches itself
local function to_pattern(path) return (path:gsub('[%[%]{}()*?!+@\\]', '\\%0')) end

local function redraw_status()
  local ok, lualine = pcall(require, 'lualine')
  if ok then
    lualine.refresh({ place = { 'statusline' } })
  else
    vim.cmd.redrawstatus()
  end
end

--- Refresh `b:yaml_schema_name` once the server has had time to apply a new
--- configuration, in case no `DiagnosticChanged` comes to do it
local function refresh_name_later(bufnr)
  vim.defer_fn(function()
    if vim.api.nvim_buf_is_valid(bufnr) then M.refresh_name(bufnr) end
  end, 1500)
end

local notify = require('util.notify').titled('YAML schema')

--- SchemaStore catalog, when the plugin is loaded
---@return {name: string, description?: string, url: string, fileMatch?: string[]}[]
local function schemastore()
  local ok, store = pcall(require, 'schemastore')
  return ok and store.json.load().schemas or {}
end

-- CRDs catalog ---------------------------------------------------------------

local function read_crds_cache()
  local stat = vim.uv.fs_stat(CRDS_CACHE)
  if not stat then return nil, true end
  local fd = io.open(CRDS_CACHE, 'r')
  if not fd then return nil, true end
  local ok, paths = pcall(vim.json.decode, fd:read('*a'))
  fd:close()
  if not ok or type(paths) ~= 'table' then return nil, true end
  return paths, os.time() - stat.mtime.sec > CRDS_TTL
end

--- Load the list of CRD schemas of the datreeio CRDs catalog, from the cache
--- or, once a week, from GitHub
---@param callback fun(paths: string[]?)
local function load_crds(callback)
  if crds then return callback(crds) end
  local cached, stale = read_crds_cache()
  if not stale then
    crds = cached
    return callback(crds)
  end
  if vim.fn.executable('curl') == 0 then return callback(cached) end
  notify('Fetching the CRDs catalog…')
  require('util.system').run({
    'curl',
    '-fsSL',
    '--max-time',
    '20',
    '-H',
    'Accept: application/vnd.github+json',
    CRDS_TREE,
  }, { timeout = 30000, max_bytes = 32 * 1024 * 1024 }, function(out)
    local ok, tree = pcall(vim.json.decode, out.stdout or '')
    if
      out.code ~= 0
      or out.cut
      or not ok
      or type(tree) ~= 'table'
      or type(tree.tree) ~= 'table'
    then
      notify('Cannot fetch the CRDs catalog', vim.log.levels.WARN)
      -- Not again this session: offline, each pick would wait 20 s
      crds = cached or {}
      return callback(crds)
    end
    local paths = {}
    for _, node in ipairs(tree.tree) do
      if node.path:match('^[^/]+/[^/]+%.json$') then
        table.insert(paths, node.path)
      end
    end
    vim.fn.mkdir(vim.fs.dirname(CRDS_CACHE), 'p')
    local fd = io.open(CRDS_CACHE, 'w')
    if fd then
      fd:write(vim.json.encode(paths))
      fd:close()
    end
    crds = paths
    callback(crds)
  end)
end

-- Kubernetes -----------------------------------------------------------------

--- `apiVersion` and `kind` of the YAML document at `row` (1-based)
---@return {group: string, version: string, kind: string}?
local function get_gvk(bufnr, row)
  local lines = get_lines(bufnr)
  local first, last = 1, #lines
  for i = row, 1, -1 do
    if is_separator(lines[i]) then
      first = i + 1
      break
    end
  end
  for i = row + 1, #lines do
    if is_separator(lines[i]) then
      last = i - 1
      break
    end
  end
  local api_version, kind
  for i = first, last do
    api_version = api_version
      or lines[i]:match('^apiVersion:%s*["\']?([^"\'%s#]+)')
    kind = kind or lines[i]:match('^kind:%s*["\']?([^"\'%s#]+)')
  end
  if not api_version or not kind then return nil end
  local group, version = api_version:match('^(.*)/(.*)$')
  return { group = group or '', version = version or api_version, kind = kind }
end

--- Schema URL of a single Kubernetes kind: from the CRDs catalog when it
--- holds the kind, from kubernetes-json-schema otherwise
local function kubernetes_uri(client, gvk)
  local crd = ('%s/%s_%s.json'):format(
    gvk.group:lower(),
    gvk.kind:lower(),
    gvk.version:lower()
  )
  local builtin = gvk.group == ''
    or not gvk.group:find('.', 1, true)
    or vim.endswith(gvk.group, '.k8s.io')
  if
    gvk.group ~= ''
    and (crds and vim.list_contains(crds, crd) or not crds and not builtin)
  then
    return CRDS_CATALOG .. '/' .. crd
  end
  local version = vim.tbl_get(client.settings, 'yaml', 'kubernetesVersion')
  local dir = (version and 'v' .. version:gsub('^v', '') or 'master')
    .. '-standalone-strict'
  -- kubernetes-json-schema names a file after the first label of the group
  -- only: `networking.k8s.io/v1` `Ingress` is `ingress-networking-v1.json`.
  local group = gvk.group == '' and '' or '-' .. gvk.group:match('^[^.]+')
  return ('%s/%s/%s%s-%s.json'):format(
    KUBERNETES_SCHEMAS,
    dir,
    gvk.kind:lower(),
    group,
    gvk.version:lower()
  )
end

-- Detection ------------------------------------------------------------------

--- Content matchers, tried in order on buffers of the plain `yaml` filetype
---@type {name: string, uri: string, match: fun(lines: string[]): boolean}[]
M.matchers = {
  {
    name = 'cloud-init',
    uri = CLOUD_INIT,
    match = function(lines) return (lines[1] or ''):match('^#cloud%-config') end,
  },
  {
    name = 'Kubernetes',
    uri = KUBERNETES,
    match = function(lines)
      local api_version, kind = false, false
      for _, line in ipairs(lines) do
        api_version = api_version or line:match('^apiVersion:%s*%S') ~= nil
        kind = kind or line:match('^kind:%s*%S') ~= nil
        if api_version and kind then return true end
      end
      return false
    end,
  },
  {
    -- A detection rule: no fixed file name, but always these two mappings
    name = 'Sigma',
    uri = SIGMA,
    match = function(lines)
      local logsource, detection = false, false
      for _, line in ipairs(lines) do
        logsource = logsource or line:match('^logsource:') ~= nil
        detection = detection or line:match('^detection:') ~= nil
        if logsource and detection then return true end
      end
      return false
    end,
  },
}

local function match(bufnr)
  if vim.bo[bufnr].filetype ~= 'yaml' then return nil end
  local lines = get_lines(bufnr, 500)
  for _, matcher in ipairs(M.matchers) do
    if matcher.match(lines) then return matcher end
  end
end

--- Point `yaml.schemas` of the server at `uri` for this buffer only
---@param bufnr integer
---@param schema {uri: string, name: string}
---@param auto? boolean
function M.set(bufnr, schema, auto)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local client = get_client(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if not client or path == '' then
    return notify('No yamlls attached to a file here', vim.log.levels.WARN)
  end
  M.reset(bufnr, true)
  local pattern = to_pattern(path)
  local yaml = client.settings.yaml or {}
  client.settings.yaml = yaml
  yaml.schemas = yaml.schemas or {}
  local patterns = yaml.schemas[schema.uri] or {}
  if type(patterns) == 'string' then patterns = { patterns } end
  table.insert(patterns, pattern)
  yaml.schemas[schema.uri] = patterns
  vim.b[bufnr].yaml_schema_choice = {
    uri = schema.uri,
    name = schema.name,
    auto = auto or false,
    pattern = pattern,
  }
  client:notify(
    'workspace/didChangeConfiguration',
    { settings = client.settings }
  )
  -- Show the choice right away; the server confirms it once it has
  -- revalidated the buffer, which `DiagnosticChanged` catches
  vim.b[bufnr].yaml_schema_name = M.get_name(schema.uri, schema.name)
  redraw_status()
  refresh_name_later(bufnr)
end

--- Drop the schema set for this buffer, and let detection run again
---@param bufnr integer
---@param silent? boolean do not tell the server
function M.reset(bufnr, silent)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  ---@type util.yaml_schema.Choice?
  local choice = vim.b[bufnr].yaml_schema_choice
  if not choice then return end
  vim.b[bufnr].yaml_schema_choice = nil
  for _, client in ipairs(vim.lsp.get_clients({ name = 'yamlls' })) do
    local schemas = vim.tbl_get(client.settings, 'yaml', 'schemas') or {}
    local patterns = schemas[choice.uri]
    if type(patterns) == 'table' then
      patterns = vim.tbl_filter(
        function(p) return p ~= choice.pattern end,
        patterns
      )
      schemas[choice.uri] = #patterns > 0 and patterns or nil
    elseif patterns == choice.pattern then
      schemas[choice.uri] = nil
    end
    if not silent then
      client:notify(
        'workspace/didChangeConfiguration',
        { settings = client.settings }
      )
    end
  end
  if not silent and vim.api.nvim_buf_is_loaded(bufnr) then
    vim.b[bufnr].yaml_schema_name = nil
    redraw_status()
    refresh_name_later(bufnr)
  end
end

--- Match the buffer on its content when the server has no schema for it
---@param bufnr integer
function M.detect(bufnr)
  local client = get_client(bufnr)
  ---@type util.yaml_schema.Choice?
  local choice = vim.b[bufnr].yaml_schema_choice
  if not client or choice and not choice.auto then return end
  local matched = match(bufnr)
  if choice and matched and choice.uri == matched.uri then return end
  if choice then M.reset(bufnr) end
  if not matched then return end
  client:request(
    ---@diagnostic disable-next-line: param-type-mismatch
    'yaml/get/jsonSchema',
    { vim.uri_from_bufnr(bufnr) },
    function(err, result)
      if err or (result and #result > 0) then return end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      -- Picked by hand while the server was asked: that choice stands
      local now = vim.b[bufnr].yaml_schema_choice
      if now and not now.auto then return end
      M.set(bufnr, matched, true)
    end,
    bufnr
  )
end

-- Local schemas --------------------------------------------------------------

local LOCAL_EXTENSIONS = { json = true, yaml = true, yml = true }

local function is_local(uri)
  return uri:sub(1, 1) == '/' or vim.startswith(uri, 'file://')
end

--- A schema URI as a path when it is a local file, as is otherwise
local function to_path(uri)
  return vim.startswith(uri, 'file://') and vim.uri_to_fname(uri) or uri
end

--- Project of the buffer, where local schemas are looked for
local function get_root(bufnr)
  local client = get_client(bufnr)
  return client and client.root_dir
    or vim.fs.root(bufnr, '.git')
    or assert(vim.uv.cwd())
end

--- Whether a file of the project looks like a schema: named after one, or
--- kept in a `schema`/`schemas` directory
local function looks_like_schema(path)
  local name = vim.fs.basename(path):lower()
  return name:match('schema%.json$') ~= nil
    or name:match('schema%.ya?ml$') ~= nil
    or path:lower():match('/%.?schemas?/') ~= nil
end

--- A path to show: relative to the project when inside it
local function display_path(path, root)
  if vim.startswith(path, root .. '/') then return path:sub(#root + 2) end
  return vim.fn.fnamemodify(path, ':~')
end

--- Path to `path` from the directory `from`, `./` or `../` prefixed
local function relative_path(from, path)
  local a = vim.split(from, '/', { trimempty = true })
  local b = vim.split(path, '/', { trimempty = true })
  local i = 1
  while a[i] and b[i] and a[i] == b[i] do
    i = i + 1
  end
  local parts = {}
  for _ = i, #a do
    table.insert(parts, '..')
  end
  for j = i, #b do
    table.insert(parts, b[j])
  end
  local rel = table.concat(parts, '/')
  return vim.startswith(rel, '..') and rel or './' .. rel
end

--- Schema files on this machine: those of the project of the buffer, and
--- every JSON or YAML file under the directories of `DyNeo.yaml_schema_dirs`
---@param bufnr integer
---@param callback fun(paths: string[], root: string)
local function find_local(bufnr, callback)
  local root = get_root(bufnr)
  local dirs = vim.tbl_filter(
    function(dir) return vim.fn.isdirectory(dir) == 1 end,
    vim.tbl_map(
      function(dir) return vim.fs.normalize(dir) end,
      DyNeo.yaml_schema_dirs or {}
    )
  )
  local function finish(paths)
    local found, seen = {}, {}
    for _, path in ipairs(paths) do
      path = vim.fs.normalize(path)
      local ext = (path:match('%.(%w+)$') or ''):lower()
      local in_dirs = vim.iter(dirs):any(
        function(dir) return vim.startswith(path, dir .. '/') end
      )
      if
        not seen[path]
        and LOCAL_EXTENSIONS[ext]
        and (in_dirs or looks_like_schema(path))
      then
        seen[path] = true
        table.insert(found, path)
      end
    end
    table.sort(found)
    callback(found, root)
  end
  local fd = vim.fn.executable('fd') == 1 and 'fd'
    or vim.fn.executable('fdfind') == 1 and 'fdfind'
  if fd then
    local cmd = {
      fd,
      '--type=f',
      '--absolute-path',
      '--hidden',
      '--exclude=.git',
      '--exclude=node_modules',
      '--extension=json',
      '--extension=yaml',
      '--extension=yml',
      '.',
      root,
    }
    vim.list_extend(cmd, dirs)
    -- A project as large as `$HOME` must not hold the picker back
    require('util.system').run(cmd, { timeout = 3000 }, function(out)
      if out.timed_out or out.cut then
        notify(
          'Local schema files: the search was cut short, some may be missing',
          vim.log.levels.WARN
        )
      end
      finish(vim.split(out.stdout or '', '\n', { trimempty = true }))
    end)
    return
  end
  local paths, walked = {}, 0
  for _, dir in ipairs(vim.list_extend({ root }, dirs)) do
    for name, type in
      vim.fs.dir(dir, {
        depth = 8,
        -- Despite its name, `skip` answers whether to descend into a directory
        skip = function(n) return n ~= '.git' and n ~= 'node_modules' end,
      })
    do
      walked = walked + 1
      if walked > M.MAX_WALK then break end
      if type == 'file' then table.insert(paths, dir .. '/' .. name) end
    end
    if walked > M.MAX_WALK then
      notify(
        (
          'Local schema files: stopped after %d entries, install fd to search'
          .. ' the whole project'
        ):format(M.MAX_WALK),
        vim.log.levels.WARN
      )
      break
    end
  end
  finish(paths)
end

-- Modeline -------------------------------------------------------------------

--- Write `schema` as a modeline at the top of the YAML document under the
--- cursor, replacing the one already there
---@param bufnr integer
---@param schema {uri: string}
function M.insert_modeline(bufnr, schema)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local uri = schema.uri
  if uri == KUBERNETES then
    local gvk = get_gvk(bufnr, row)
    local client = get_client(bufnr)
    if not gvk or not client then
      return notify(
        'No `apiVersion` and `kind` in this document',
        vim.log.levels.WARN
      )
    end
    uri = kubernetes_uri(client, gvk)
  elseif is_local(uri) then
    -- yamlls resolves a relative path from the directory of the file, so
    -- a schema of the same project keeps working wherever it is cloned
    local path = to_path(uri)
    local file = vim.api.nvim_buf_get_name(bufnr)
    local root = get_root(bufnr)
    if
      vim.startswith(path, root .. '/') and vim.startswith(file, root .. '/')
    then
      uri = relative_path(vim.fs.dirname(file), path)
    else
      uri = path
    end
  end
  local lines = get_lines(bufnr)
  local first = 1
  for i = row, 1, -1 do
    if is_separator(lines[i]) then
      first = i + 1
      break
    end
  end
  -- An existing modeline in the comments that open the document
  for i = first, #lines do
    if not lines[i]:match('^%s*#') then break end
    if lines[i]:match('^%s*#%s*yaml%-language%-server:') then
      vim.api.nvim_buf_set_lines(bufnr, i - 1, i, false, { MODELINE .. uri })
      return
    end
  end
  vim.api.nvim_buf_set_lines(bufnr, first - 1, first - 1, false, {
    MODELINE .. uri,
  })
end

--- Use a schema file of this machine for the buffer, or with `modeline`,
--- write it as a modeline
---@param bufnr integer
---@param path string
---@param modeline? boolean
function M.use_file(bufnr, path, modeline)
  bufnr = bufnr == 0 and vim.api.nvim_get_current_buf() or bufnr
  path = vim.fs.normalize(vim.fn.fnamemodify(vim.fn.expand(path), ':p'))
  if vim.fn.filereadable(path) == 0 then
    return notify('Cannot read ' .. path, vim.log.levels.WARN)
  end
  local schema = { uri = path, name = vim.fs.basename(path) }
  if modeline then return M.insert_modeline(bufnr, schema) end
  M.set(bufnr, schema)
end

--- Ask for the path of a schema file, anywhere on this machine
---@param bufnr integer
---@param modeline? boolean
function M.browse(bufnr, modeline)
  vim.ui.input({
    prompt = 'Schema file: ',
    default = get_root(bufnr) .. '/',
    completion = 'file',
  }, function(input)
    if input and input ~= '' then M.use_file(bufnr, input, modeline) end
  end)
end

-- Picker ---------------------------------------------------------------------

local function preview(schema)
  local text = { '# ' .. schema.name, '', '`' .. schema.uri .. '`', '' }
  if schema.description then
    vim.list_extend(text, vim.split(schema.description, '\n'))
    table.insert(text, '')
  end
  if schema.file_match and #schema.file_match > 0 then
    table.insert(text, '## Files')
    table.insert(text, '')
    for _, glob in ipairs(schema.file_match) do
      table.insert(text, '- `' .. glob .. '`')
    end
  end
  return { text = table.concat(text, '\n'), ft = 'markdown' }
end

--- Every schema to choose from, the ones in use first
---@param in_use {uri: string, name?: string, description?: string}[]
---@param known {uri: string, name?: string, description?: string}[]
---@param locals string[] schema files of this machine
---@param root string project of the buffer
---@return util.yaml_schema.Schema[]
local function collect(in_use, known, locals, root)
  local schemas, seen = {}, {}
  local function add(schema)
    -- The server hands local schemas back as `file://` URIs
    if is_local(schema.uri) then
      schema.uri = to_path(schema.uri)
      schema.name = schema.name or display_path(schema.uri, root)
      schema.file = schema.uri
      schema.preview = 'file'
    end
    if seen[schema.uri] then return end
    seen[schema.uri] = true
    schema.name = schema.name or M.get_name(schema.uri)
    table.insert(schemas, schema)
  end
  for _, s in ipairs(in_use) do
    add({
      uri = s.uri,
      name = s.name,
      description = s.description,
      source = 'in use',
    })
  end
  for _, path in ipairs(locals) do
    add({ uri = path, name = display_path(path, root), source = 'local' })
  end
  add({
    uri = '',
    name = 'Browse for a local file…',
    source = 'local',
    browse = true,
    preview = {
      text = 'Type the path of a JSON or YAML schema anywhere on this machine',
      ft = 'markdown',
    },
  })
  add({
    uri = KUBERNETES,
    name = 'Kubernetes',
    description = 'Built-in kinds and CRDs, picked per document by `apiVersion` and `kind`',
    source = 'kubernetes',
  })
  add({ uri = CLOUD_INIT, name = 'cloud-init', source = 'cloud-init' })
  for _, s in ipairs(schemastore()) do
    local file_match = s.fileMatch
    add({
      uri = s.url,
      name = s.name,
      description = s.description,
      source = 'schemastore',
      file_match = type(file_match) == 'string' and { file_match }
        or file_match,
    })
  end
  -- Schemas the server knows of besides SchemaStore: `yaml.schemas`
  for _, s in ipairs(known) do
    add({
      uri = s.uri,
      name = s.name,
      description = s.description,
      source = 'yamlls',
    })
  end
  for _, path in ipairs(crds or {}) do
    local group, kind, version = path:match('^([^/]+)/([^_]+)_(.+)%.json$')
    if group then
      add({
        uri = CRDS_CATALOG .. '/' .. path,
        name = ('%s (%s/%s)'):format(kind, group, version),
        source = 'crds-catalog',
      })
    end
  end
  return schemas
end

local function open(bufnr, schemas, modeline)
  ---@type util.yaml_schema.Choice?
  local choice = vim.b[bufnr].yaml_schema_choice
  local function apply(schema)
    if not schema then return end
    if schema.reset then return M.reset(bufnr) end
    if schema.browse then return M.browse(bufnr, modeline) end
    if modeline then return M.insert_modeline(bufnr, schema) end
    M.set(bufnr, schema)
  end
  if choice and not modeline then
    table.insert(schemas, 1, {
      uri = '',
      name = 'Reset to auto-detection',
      description = 'Currently: ' .. choice.name,
      source = 'reset',
      reset = true,
      preview = {
        text = 'Drop `' .. choice.name .. '` and detect the schema again',
        ft = 'markdown',
      },
    })
  end
  local title = modeline and 'YAML schema modeline' or 'YAML schema'
  if not package.loaded['snacks'] then
    return vim.ui.select(schemas, {
      prompt = title,
      format_item = function(s) return ('%s [%s]'):format(s.name, s.source) end,
    }, apply)
  end
  local width = 0
  for _, s in ipairs(schemas) do
    width = math.max(width, vim.api.nvim_strwidth(s.name))
  end
  Snacks.picker.pick({
    title = title,
    items = vim.tbl_map(
      function(s)
        return vim.tbl_extend('force', s, {
          text = s.name .. ' ' .. s.source .. ' ' .. s.uri,
          preview = s.preview or preview(s),
        })
      end,
      schemas
    ),
    format = function(item)
      local active = choice and item.uri == choice.uri
      return {
        { active and '● ' or '  ', 'SnacksPickerSpecial' },
        {
          item.name .. (' '):rep(width - vim.api.nvim_strwidth(item.name)),
          'SnacksPickerLabel',
        },
        { '  ' },
        { item.source, 'SnacksPickerComment' },
      }
    end,
    preview = 'preview',
    confirm = function(picker, item)
      picker:close()
      apply(item)
    end,
    actions = {
      yaml_modeline = function(picker, item)
        picker:close()
        if not item or item.reset then return end
        if item.browse then return M.browse(bufnr, true) end
        M.insert_modeline(bufnr, item)
      end,
    },
    win = {
      input = {
        keys = {
          ['<M-m>'] = {
            'yaml_modeline',
            mode = { 'n', 'i' },
            desc = 'Insert as modeline',
          },
        },
      },
    },
  })
end

--- Pick a schema for the buffer, or with `modeline`, one to write as a
--- modeline in the document under the cursor
---@param bufnr? integer
---@param modeline? boolean
function M.select(bufnr, modeline)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local client = get_client(bufnr)
  if not client then
    return notify('No yamlls attached to this buffer', vim.log.levels.WARN)
  end
  local uri = vim.uri_from_bufnr(bufnr)
  load_crds(function()
    find_local(bufnr, function(locals, root)
      client:request(
        ---@diagnostic disable-next-line: param-type-mismatch
        'yaml/get/all/jsonSchemas',
        { uri },
        function(_, result)
          local in_use, known = {}, {}
          for _, s in ipairs(result or {}) do
            table.insert(s.usedForCurrentFile and in_use or known, s)
          end
          open(bufnr, collect(in_use, known, locals, root), modeline)
        end,
        bufnr
      )
    end)
  end)
end

-- Server ---------------------------------------------------------------------

--- Human name of a schema URI
---@param uri string
---@param title? string title of the schema, when nothing better is known
---@return string
function M.get_name(uri, title)
  if uri == KUBERNETES then return 'Kubernetes' end
  if uri == CLOUD_INIT then return 'cloud-init' end
  if is_local(uri) then return vim.fs.basename(to_path(uri)) end
  if not names then
    names = {}
    for _, schema in ipairs(schemastore()) do
      names[schema.url] = schema.name
    end
  end
  if names[uri] then return names[uri] end
  if vim.startswith(uri, KUBERNETES_SCHEMAS) then
    local file = uri:match('([^/]+)%.json$')
    return file == 'all' and 'Kubernetes' or 'Kubernetes ' .. file
  end
  local group, kind, version =
    uri:match('/CRDs%-catalog/[^/]+/([^/]+)/([^_/]+)_([^/]+)%.json$')
  if group then return ('%s (%s/%s)'):format(kind, group, version) end
  return title or 'Custom'
end

--- Ask the server which schema the buffer uses, and keep its name in
--- `b:yaml_schema_name` for the statusline. Asking on every redraw instead
--- either blocks, or times out while the server loads a schema just chosen.
---@param bufnr integer
function M.refresh_name(bufnr)
  local client = get_client(bufnr)
  if not client then return end
  client:request(
    ---@diagnostic disable-next-line: param-type-mismatch
    'yaml/get/jsonSchema',
    { vim.uri_from_bufnr(bufnr) },
    function(err, result)
      if err or not vim.api.nvim_buf_is_valid(bufnr) then return end
      local schema = result and result[1]
      local name = schema and schema.uri and M.get_name(schema.uri, schema.name)
      if vim.b[bufnr].yaml_schema_name == name then return end
      vim.b[bufnr].yaml_schema_name = name
      redraw_status()
    end,
    bufnr
  )
end

local group = vim.api.nvim_create_augroup('util.yaml_schema', { clear = true })

--- `on_init` of yamlls: hand SchemaStore to the server and start detection
---@param client vim.lsp.Client
function M.on_init(client)
  local ok, store = pcall(require, 'schemastore')
  if ok then client:notify('json/schemaAssociations', store.yaml.schemas()) end
  vim.api.nvim_clear_autocmds({ group = group })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(ev)
      local attached = vim.lsp.get_client_by_id(ev.data.client_id)
      if not attached or attached.name ~= 'yamlls' then return end
      -- :DyYamlSchema [modeline] [path], or :DyYamlSchema reset
      vim.api.nvim_buf_create_user_command(ev.buf, 'DyYamlSchema', function(cmd)
        local args = vim.deepcopy(cmd.fargs)
        if args[1] == 'reset' then return M.reset(ev.buf) end
        local modeline = args[1] == 'modeline'
        if modeline then table.remove(args, 1) end
        if #args > 0 then
          return M.use_file(ev.buf, table.concat(args, ' '), modeline)
        end
        M.select(ev.buf, modeline)
      end, {
        nargs = '*',
        complete = function(lead, line)
          local words = vim.split(line, '%s+', { trimempty = true })
          local first = #words == 1 or (#words == 2 and lead ~= '')
          local subcommands = first
              and vim.tbl_filter(
                function(s) return vim.startswith(s, lead) end,
                { 'modeline', 'reset' }
              )
            or {}
          return vim.list_extend(
            subcommands,
            vim.fn.getcompletion(lead, 'file')
          )
        end,
        desc = 'Pick a YAML schema for the buffer',
      })
      M.detect(ev.buf)
      M.refresh_name(ev.buf)
    end,
  })
  -- The server revalidates a buffer whenever its schema may have changed: a
  -- new configuration, a modeline typed in, a schema finished loading. Its
  -- own diagnostics only: yamllint, betterleaks and the rest change nothing
  -- of the schema, and each would cost a request.
  vim.api.nvim_create_autocmd('DiagnosticChanged', {
    group = group,
    callback = function(ev)
      local client = get_client(ev.buf)
      if not client then return end
      local first = ((ev.data or {}).diagnostics or {})[1]
      if
        first
        and first.namespace ~= vim.lsp.diagnostic.get_namespace(client.id)
      then
        return
      end
      M.refresh_name(ev.buf)
    end,
  })
  vim.api.nvim_create_autocmd('BufWritePost', {
    group = group,
    callback = function(ev) M.detect(ev.buf) end,
  })
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    callback = function(ev) M.reset(ev.buf) end,
  })
end

return M
