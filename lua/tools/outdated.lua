--- Dependencies a newer release is out for, held to the quarantine window
---
--- `:DyOutdated` reads the dependencies of the manifest in the buffer --
--- `package.json`, `go.mod`, `requirements*.txt`, `pyproject.toml`, the
--- providers and registry modules of Terraform, the actions of a GitHub
--- workflow -- asks each one's registry what it released and when, and puts
--- at the end of its line the newest release out for longer than
--- `DyNeo.quarantine_window`: the one an update may move to. A newer release
--- still inside the window is named as held. A release whose date the
--- registry does not give is never offered, nor a prerelease, nor one npm
--- deprecated or PyPI yanked.
---
--- A release is written as precisely as the version it would replace, so
--- what is shown is what `:DyOutdated bump` writes into the line under the
--- cursor: `~> 5.0` becomes `~> 5.31`, `@v4` `@v5`, the operator kept. Only
--- the names of the dependencies leave the machine, to the registry of each
--- -- deps.dev for npm, whose own answer is too big to fetch for a line.
local M = {}

local system = require('util.system')
local notify = require('util.notify').titled('Outdated')

--- Milliseconds one registry request may take
M.TIMEOUT = 30 * 1000

--- Requests running at once
M.PARALLEL = 4

--- Bytes read of one answer: PyPI's document of a package describes every
--- file of every release, a few MiB for one released daily
M.MAX_BYTES = 16 * 1024 * 1024

--- Seconds a registry's answer is reused within a session
M.CACHE_TTL = 60 * 60

--- Go releases asked about, newest first, for the date the list leaves out
M.GO_LOOKUPS = 8

M.ns = vim.api.nvim_create_namespace('dy_outdated')

--- Seconds since the epoch; a field so the specs can fix it
---@return integer
function M.now() return os.time() end

---@class DyOutdatedDep
---@field kind 'npm'|'go'|'pypi'|'tf-provider'|'tf-module'|'action'
---@field name string As the registry knows it
---@field version string As written: `1.2.0`, `v4`, `5.0`
---@field line integer 1-based
---@field col integer 1-based byte where `version` starts on its line
---@field pinned? boolean An action pinned to a commit: shown, never bumped

---@class DyOutdatedRelease
---@field version string
---@field time? integer Seconds since the epoch it was published
---@field prerelease? boolean

--- The reader of the manifest at `path`, or nil when it is none
---@param path string
---@return string?
function M.manifest(path)
  local base = vim.fs.basename(path)
  if base == 'package.json' then return 'npm' end
  if base == 'go.mod' then return 'go' end
  if base:match('^requirements.*%.txt$') then return 'pypi' end
  if base == 'pyproject.toml' then return 'pyproject' end
  if base:match('%.tf$') then return 'terraform' end
  if
    path:match('/%.github/workflows/[^/]+%.ya?ml$')
    or base == 'action.yml'
    or base == 'action.yaml'
  then
    return 'actions'
  end
  return nil
end

--- The first version in `text`, and where it starts: `^1.2.3` gives
--- `1.2.3`, `~> 5.0` `5.0`, `>=2.0,<3` `2.0`
---@param text string
---@return string? version
---@return integer? start
local function version_in(text)
  local start, version = text:match('()(v?%d+[%w%.%-%+]*)')
  if not version then return nil end
  -- `1.2.3-1.4.0` is no npm version: a hyphen range written without spaces
  return (version:gsub('[%.%-%+]+$', '')), start
end

--- `line` with every string literal blanked, for counting what is code
---@param line string
---@return string
local function code_of(line)
  local code = line:gsub('"[^"]*"', '""')
  return (code:gsub('%s*#.*$', ''):gsub('%s*//.*$', ''))
end

--- A PEP 508 requirement: its name, normalized, and the version of its first
--- comparison, or nil for one without -- a URL, a bare name
---@param text string
---@return string? name
---@return string? version
---@return integer? start Where the version starts in `text`
local function pep508(text)
  local name, rest_at = text:match('^%s*([%a%d][%w%._%-]*)()')
  if not name or text:find('://', 1, true) or text:find('%s@%s') then
    return nil
  end
  local rest = text:sub(rest_at):gsub('%s*;.*$', '')
  local op_at = rest:find('[=<>~!]=?')
  if not op_at then return nil end
  local version, start = version_in(rest:sub(op_at))
  if not version then return nil end
  return name:lower():gsub('[%._]+', '-'), version, rest_at + op_at + start - 2
end

local readers = {}

--- The registry ranges of `dependencies` and its kin; a path, a URL, a tag
--- or an alias names no release to compare
local NPM_SECTIONS = {
  dependencies = true,
  devDependencies = true,
  peerDependencies = true,
  optionalDependencies = true,
}

function readers.npm(lines)
  local deps, inside = {}, false
  for number, line in ipairs(lines) do
    local section, after = line:match('^%s*"(%w+)"%s*:%s*{()')
    -- An object on one line, `"devDependencies": { "x": "1.0.0" }`, is read
    -- from its brace on
    local from = 1
    if section and NPM_SECTIONS[section] then
      inside, from = true, after
    end
    if inside then
      for at, name, spec in line:sub(from):gmatch('()"([^"]+)"%s*:%s*"([^"]*)"') do
        at = at + from - 1
        if spec:match('^[%^~<>=%s]*v?%d') then
          local version, start = version_in(spec)
          local spec_at = line:find('"' .. spec .. '"', at, true)
          if version and spec_at then
            table.insert(deps, {
              kind = 'npm',
              name = name,
              version = version,
              line = number,
              col = spec_at + start,
            })
          end
        end
      end
      if code_of(line):find('}', 1, true) then inside = false end
    end
  end
  return deps
end

--- A pseudo-version names a commit, not a release
local PSEUDO = '%-?%d%d%d%d%d%d%d%d%d%d%d%d%d%d%-%x+$'

function readers.go(lines)
  local deps, block = {}, false
  for number, line in ipairs(lines) do
    local path, version
    if block then
      if line:match('^%s*%)') then
        block = false
      else
        path, version = line:match('^%s*(%S+)%s+(v%d%S*)')
      end
    elseif line:match('^require%s*%(') then
      block = true
    else
      path, version = line:match('^require%s+(%S+)%s+(v%d%S*)')
    end
    if path and not version:match(PSEUDO) then
      table.insert(deps, {
        kind = 'go',
        name = path,
        version = version,
        line = number,
        col = assert(line:find(version, #path + 1, true)),
      })
    end
  end
  return deps
end

function readers.pypi(lines)
  local deps = {}
  for number, line in ipairs(lines) do
    local text = line:gsub('%s+#.*$', '')
    if not text:match('^%s*[#%-]') then
      local name, version, start = pep508(text)
      if name then
        table.insert(deps, {
          kind = 'pypi',
          name = name,
          version = version,
          line = number,
          col = start,
        })
      end
    end
  end
  return deps
end

--- The tables of `pyproject.toml` whose arrays hold PEP 508 strings, and
--- those whose keys are Poetry dependencies
local function pyproject_table(name)
  if name == 'project' or name == 'project.optional-dependencies' then
    return 'arrays'
  end
  if name == 'dependency-groups' then return 'arrays' end
  if
    name:match('^tool%.poetry%.dependencies$')
    or name:match('^tool%.poetry%.dev%-dependencies$')
    or name:match('^tool%.poetry%.group%.[^.]+%.dependencies$')
  then
    return 'poetry'
  end
  return nil
end

function readers.pyproject(lines)
  local deps, kind, in_array = {}, nil, false
  local function add(name, version, number, col)
    table.insert(deps, {
      kind = 'pypi',
      name = name,
      version = version,
      line = number,
      col = col,
    })
  end
  for number, line in ipairs(lines) do
    local header = line:match('^%s*%[([^%[%]]+)%]%s*$')
    if header then
      kind, in_array = pyproject_table(vim.trim(header)), false
    elseif kind == 'arrays' then
      local key = line:match('^%s*([%w_%-]+)%s*=%s*%[')
      -- Under `[project]` only `dependencies` holds requirements
      if key and (key == 'dependencies' or not line:match('^%s*name')) then
        in_array = true
      end
      if in_array then
        local from = key and line:find('[', 1, true) or 1
        for at, text in line:sub(from):gmatch('()"([^"]*)"') do
          local name, version, start = pep508(text)
          if name then add(name, version, number, from + at + start - 1) end
        end
        if code_of(line):find(']', 1, true) then in_array = false end
      end
    elseif kind == 'poetry' then
      local name, value_at, value = line:match('^%s*([%w_%.%-]+)%s*=%s*()(.*)$')
      if name and name ~= 'python' then
        local spec_at, spec = value:match('^()"([^"]*)"')
        if not spec then
          spec_at, spec = value:match('version%s*=%s*()"([^"]*)"')
        end
        if spec and spec:match('^[%^~<>=%s]*v?%d') then
          local version, start = version_in(spec)
          if version then
            add(
              name:lower():gsub('[%._]+', '-'),
              version,
              number,
              value_at + spec_at + start - 1
            )
          end
        end
      end
    end
  end
  return deps
end

--- `ns/name` of a provider source on the public registry, or nil
---@param source string
---@return string?
local function provider_source(source)
  source = source:gsub('^registry%.terraform%.io/', '')
  return source:match('^[%w_%-]+/[%w_%-]+$') and source:lower() or nil
end

--- `ns/name/provider` of a module source on the public registry, or nil
---@param source string
---@return string?
local function module_source(source)
  source = source:gsub('^registry%.terraform%.io/', '')
  return source:match('^[%w_%-]+/[%w_%-]+/[%w_%-]+$') and source or nil
end

function readers.terraform(lines)
  local deps, depth = {}, 0
  local providers_at, module_at, entry
  local function finish(kind, name)
    if name and entry.version then
      table.insert(deps, {
        kind = kind,
        name = name,
        version = entry.version,
        line = entry.line,
        col = entry.col,
      })
    end
  end
  for number, line in ipairs(lines) do
    local code = code_of(line)
    if not providers_at and not module_at then
      if code:match('required_providers%s*{') then
        providers_at = depth + 1
      elseif code:match('^%s*module%s+""%s*{') then
        module_at = depth + 1
        entry = { depth = module_at, opened = number }
      end
    elseif providers_at and depth == providers_at then
      if code:match('^%s*[%w_%-]+%s*=%s*{') then
        entry = { depth = providers_at + 1, opened = number }
      end
    end
    -- The entry's own `source` and `version`, not `cluster_version` nor
    -- one of a block nested in it
    if entry and (number == entry.opened or depth == entry.depth) then
      local padded = ' ' .. line
      entry.source = padded:match('[%s{,]source%s*=%s*"([^"]+)"')
        or entry.source
      local at, spec = padded:match('[%s{,]version%s*=%s*"()([^"]+)"')
      if spec then
        local version, start = version_in(spec)
        if version then
          -- `at` counts the space put in front
          entry.version, entry.line, entry.col = version, number, at + start - 2
        end
      end
    end
    local _, opened = code:gsub('{', '')
    local _, closed = code:gsub('}', '')
    depth = depth + opened - closed
    if providers_at then
      if entry and depth <= providers_at then
        finish('tf-provider', entry.source and provider_source(entry.source))
        entry = nil
      end
      if depth < providers_at then providers_at = nil end
    elseif module_at and depth < module_at then
      finish('tf-module', entry.source and module_source(entry.source))
      module_at, entry = nil, nil
    end
  end
  return deps
end

function readers.actions(lines)
  local deps = {}
  for number, line in ipairs(lines) do
    local repo, ref_at, ref = line:match(
      'uses:%s*["\']?([%w_%.%-]+/[%w_%.%-]+)[^@%s"\']*@()([%w_%.%-]+)'
    )
    if repo then
      local comment_at, tag = line:match('#%s*()(v?%d[%w%.%-]*)', ref_at)
      if ref:match('^%x+$') and #ref == 40 then
        if tag then
          table.insert(deps, {
            kind = 'action',
            name = repo,
            version = tag,
            line = number,
            col = comment_at,
            pinned = true,
          })
        end
      elseif ref:match('^v?%d') then
        table.insert(deps, {
          kind = 'action',
          name = repo,
          version = ref,
          line = number,
          col = ref_at,
        })
      end
    end
  end
  return deps
end

--- The dependencies `lines` of a manifest read by `reader` name
---@param reader string As `M.manifest` names it
---@param lines string[]
---@return DyOutdatedDep[]
function M.deps(reader, lines) return readers[reader](lines) end

--- The numbers of `version`, up to its prerelease or build
---@param version string
---@return integer[]
local function numbers(version)
  local parts = {}
  for part in (version:match('^v?([%d%.]+)') or ''):gmatch('%d+') do
    table.insert(parts, tonumber(part))
  end
  return parts
end

--- Below 0, 0 or above 0 as `a` is older than `b`, the same, or newer;
--- numbers only, a part left out reading 0
---@param a string
---@param b string
---@return integer
function M.compare(a, b)
  local x, y = numbers(a), numbers(b)
  for index = 1, math.max(#x, #y) do
    local left, right = x[index] or 0, y[index] or 0
    if left ~= right then return left - right end
  end
  return 0
end

--- Whether `version` is a prerelease, as semver or PEP 440 write one
---@param version string
---@return boolean
function M.is_prerelease(version)
  local core = version:gsub('%+.*$', '')
  if core:match('^v?[%d%.]+%-') then return true end
  local lower = core:lower()
  return lower:match('%d%.?a%d') ~= nil
    or lower:match('%d%.?b%d') ~= nil
    or lower:match('%d%.?rc%d*') ~= nil
    or lower:match('%.?dev%d*$') ~= nil
    or lower:match('alpha') ~= nil
    or lower:match('beta') ~= nil
end

--- `release` written as `current` is: as many numbers, a `v` as it has one
---@param release string
---@param current string
---@return string
function M.format(release, current)
  local wanted = #numbers(current)
  local kept = vim.list_slice(numbers(release), 1, wanted)
  local text = table.concat(kept, '.')
  if current:match('^v') then text = 'v' .. text end
  if release:match('%+incompatible$') then text = text .. '+incompatible' end
  return text
end

--- The newest release out of quarantine newer than `current`, and the
--- newest one held back -- too young, or of unknown date -- newer than that;
--- both compared as precisely as `current` is written
---@param current string
---@param releases DyOutdatedRelease[]
---@param now? integer
---@return DyOutdatedRelease? aged
---@return DyOutdatedRelease? held
function M.pick(current, releases, now)
  now = now or M.now()
  local window = require('tools.lazy-quarantine').window()
  local aged, held
  for _, release in ipairs(releases) do
    local written = M.format(release.version, current)
    if
      not release.prerelease
      and not M.is_prerelease(release.version)
      and M.compare(written, current) > 0
    then
      if release.time and now - release.time >= window then
        if not aged or M.compare(release.version, aged.version) > 0 then
          aged = release
        end
      elseif not held or M.compare(release.version, held.version) > 0 then
        held = release
      end
    end
  end
  if
    held
    and aged
    and M.compare(
        M.format(held.version, current),
        M.format(aged.version, current)
      )
      <= 0
  then
    held = nil
  end
  return aged, held
end

local epoch = function(timestamp)
  return require('tools.mason-quarantine').epoch(timestamp)
end

local decoders = {}

--- The versions deps.dev lists of an npm package, the deprecated left out
---
--- npm's own document carries the publish times only in its full form,
--- which lists every manifest of every release: 15 MiB for typescript, too
--- slow to fetch for one line. deps.dev answers the same in a twentieth.
function decoders.npm(doc)
  local releases = {}
  for _, item in ipairs(type(doc.versions) == 'table' and doc.versions or {}) do
    local version = type(item) == 'table'
      and vim.tbl_get(item, 'versionKey', 'version')
    if type(version) == 'string' and not item.isDeprecated then
      table.insert(
        releases,
        { version = version, time = epoch(item.publishedAt) }
      )
    end
  end
  return releases
end

function decoders.pypi(doc)
  local releases = {}
  for version, files in
    pairs(type(doc.releases) == 'table' and doc.releases or {})
  do
    local time, live
    for _, file in ipairs(type(files) == 'table' and files or {}) do
      if not file.yanked then live = true end
      local at = epoch(file.upload_time_iso_8601 or file.upload_time)
      if at and (not time or at < time) then time = at end
    end
    if live then table.insert(releases, { version = version, time = time }) end
  end
  return releases
end

--- The versions the Terraform registry lists under `included`
---@param doc table
---@param kind string
---@return DyOutdatedRelease[]
local function terraform_versions(doc, kind)
  local releases = {}
  for _, item in ipairs(type(doc.included) == 'table' and doc.included or {}) do
    local attributes = type(item) == 'table' and item.attributes or {}
    if item.type == kind and type(attributes.version) == 'string' then
      table.insert(releases, {
        version = attributes.version,
        time = epoch(attributes['published-at']),
      })
    end
  end
  return releases
end

decoders['tf-provider'] = function(doc)
  return terraform_versions(doc, 'provider-versions')
end
decoders['tf-module'] = function(doc)
  return terraform_versions(doc, 'module-versions')
end

function decoders.action(doc)
  local releases = {}
  for _, release in ipairs(doc) do
    if
      type(release) == 'table'
      and not release.draft
      and type(release.tag_name) == 'string'
    then
      table.insert(releases, {
        version = release.tag_name,
        time = epoch(release.published_at),
        prerelease = release.prerelease == true or nil,
      })
    end
  end
  return releases
end

--- The releases of a registry's answer, `kind` naming the registry
---@param kind string
---@param doc table
---@return DyOutdatedRelease[]
function M.releases_of(kind, doc) return decoders[kind](doc) end

--- A Go module path as the proxy wants it: each capital `!` and lower case
---@param path string
---@return string
function M.go_escape(path)
  return (path:gsub('%u', function(char) return '!' .. char:lower() end))
end

--- `text` as one segment of a URL path
---@param text string
---@return string
local function encode(text)
  return (
    text:gsub(
      '[^%w%.%-_~]',
      function(char) return ('%%%02X'):format(char:byte()) end
    )
  )
end

--- Hand `on_done` what `url` answers, decoded when `json`; with `filter` a
--- jq program the answer goes through first, when jq is installed, so a
--- document of megabytes is not decoded whole on the main loop
---@param url string
---@param opts { json?: boolean, filter?: string }
---@param on_done fun(data: any, err: string?)
local function fetch(url, opts, on_done)
  local curl = {
    'curl',
    '--fail',
    '--silent',
    '--show-error',
    '--location',
    '--proto',
    '=https',
    '--max-time',
    tostring(math.floor(M.TIMEOUT / 1000)),
    '--',
    url,
  }
  local command = curl
  if opts.filter and vim.fn.executable('jq') == 1 then
    command = vim.list_extend({
      'bash',
      '-c',
      'set -o pipefail; "${@:2}" | jq -c "$1"',
      'dy_outdated',
      opts.filter,
    }, curl)
  end
  system.run(
    command,
    { timeout = M.TIMEOUT + 2000, max_bytes = M.MAX_BYTES },
    function(result)
      if result.code ~= 0 or result.missing or result.timed_out then
        return on_done(nil, system.failure(result, 'curl'))
      end
      if result.cut then
        return on_done(nil, 'the registry answered with more than can be read')
      end
      if not opts.json then return on_done(result.stdout or '') end
      local ok, data = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(data) ~= 'table' then
        return on_done(nil, 'the registry answered with something not JSON')
      end
      on_done(data)
    end
  )
end

--- What jq keeps of a PyPI document: the time and the yanked flag of each
--- file, out of the megabytes of everything else it says of them
local PYPI_FILTER = '{releases: (.releases // {}'
  .. ' | map_values(map({upload_time_iso_8601, yanked})))}'

--- The releases of Go module `path` newer than `current`: the proxy lists
--- versions without dates, so each is asked about, newest first, until one
--- is out of quarantine or `M.GO_LOOKUPS` were asked
---@param path string
---@param current string
---@param on_done fun(releases: DyOutdatedRelease[]?, err: string?)
local function go_releases(path, current, on_done)
  local base = 'https://proxy.golang.org/' .. M.go_escape(path) .. '/@v/'
  fetch(base .. 'list', {}, function(text, err)
    if not text then return on_done(nil, err) end
    local versions = vim.tbl_filter(
      function(version)
        return not M.is_prerelease(version)
          and M.compare(M.format(version, current), current) > 0
      end,
      vim.split(text, '\n', { trimempty = true })
    )
    table.sort(versions, function(a, b) return M.compare(a, b) > 0 end)
    local releases, index = {}, 0
    local window = require('tools.lazy-quarantine').window()
    local function next_version()
      index = index + 1
      local version = versions[index]
      if not version or index > M.GO_LOOKUPS then return on_done(releases) end
      fetch(base .. encode(version) .. '.info', { json = true }, function(info)
        local time = info and epoch(info.Time)
        table.insert(releases, { version = version, time = time })
        if time and M.now() - time >= window then return on_done(releases) end
        next_version()
      end)
    end
    next_version()
  end)
end

--- Hand `on_done` the releases of `dep`, from its registry
---@param dep DyOutdatedDep
---@param on_done fun(releases: DyOutdatedRelease[]?, err: string?)
local function ask(dep, on_done)
  local function decoded(kind)
    return function(doc, err)
      if not doc then return on_done(nil, err) end
      on_done(M.releases_of(kind, doc))
    end
  end
  if dep.kind == 'npm' then
    return fetch(
      'https://api.deps.dev/v3/systems/npm/packages/' .. encode(dep.name),
      { json = true },
      decoded('npm')
    )
  end
  if dep.kind == 'pypi' then
    return fetch(
      'https://pypi.org/pypi/' .. encode(dep.name) .. '/json',
      { json = true, filter = PYPI_FILTER },
      decoded('pypi')
    )
  end
  if dep.kind == 'go' then
    return go_releases(dep.name, dep.version, on_done)
  end
  if dep.kind == 'tf-provider' then
    return fetch(
      'https://registry.terraform.io/v2/providers/'
        .. dep.name
        .. '?include=provider-versions',
      { json = true },
      decoded('tf-provider')
    )
  end
  if dep.kind == 'tf-module' then
    return fetch(
      'https://registry.terraform.io/v2/modules/'
        .. dep.name
        .. '?include=module-versions',
      { json = true },
      decoded('tf-module')
    )
  end
  -- An action: GitHub's releases, through `gh` when it is installed, which
  -- spends the user's own rate limit, else anonymously
  local path = ('repos/%s/releases?per_page=100'):format(dep.name)
  if vim.fn.executable('gh') == 1 then
    return system.run(
      { 'gh', 'api', path },
      { timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
      function(result)
        local ok, doc = pcall(vim.json.decode, result.stdout or '', {
          luanil = { object = true, array = true },
        })
        if result.code ~= 0 or result.cut or not ok or type(doc) ~= 'table' then
          return on_done(nil, system.failure(result, 'gh'))
        end
        on_done(M.releases_of('action', doc))
      end
    )
  end
  fetch('https://api.github.com/' .. path, { json = true }, decoded('action'))
end

---@type table<string, { at: integer, releases: DyOutdatedRelease[] }>
local cache = {}

--- `ask`, answered from what was asked within `M.CACHE_TTL`; a failure is
--- never kept, so the next check asks again
---@param dep DyOutdatedDep
---@param on_done fun(releases: DyOutdatedRelease[]?, err: string?)
local function cached(dep, on_done)
  -- Go's lookups stop at the first aged release newer than the version
  -- written, so its answer is only good for that version
  local key = table.concat({
    dep.kind,
    dep.name,
    dep.kind == 'go' and dep.version or '',
  }, '\0')
  local hit = cache[key]
  if hit and M.now() - hit.at < M.CACHE_TTL then
    return on_done(hit.releases)
  end
  ask(dep, function(releases, err)
    if releases then cache[key] = { at = M.now(), releases = releases } end
    on_done(releases, err)
  end)
end

---@class DyOutdatedFound
---@field dep DyOutdatedDep
---@field aged? DyOutdatedRelease
---@field held? DyOutdatedRelease
---@field err? string

--- What the last check found, by buffer and by the id of its mark
---@type table<integer, table<integer, DyOutdatedFound>>
M.found = {}

--- The number of the last check of each buffer
---@type table<integer, integer>
M.runs = {}

--- Characters of a registry's error shown at the end of a line
M.ERROR_WIDTH = 80

--- How long ago `time` was, in days, for a held release
---@param time? integer
---@return string
local function age(time)
  if not time then return 'date unknown' end
  local days = math.floor((M.now() - time) / 86400)
  return days < 1 and 'out today' or ('%dd old'):format(days)
end

--- The text at the end of a dependency's line
---@param found DyOutdatedFound
---@return [string, string][]?
local function virt_text(found)
  if found.err then
    -- One line of it: curl and jq end their messages with newlines, which
    -- virtual text shows as `^@`
    local first = vim.trim(found.err):match('^[^\r\n%z]*'):gsub('%c', ' ')
    if #first > M.ERROR_WIDTH then
      first = first:sub(1, M.ERROR_WIDTH - 1) .. '…'
    end
    return { { '  ? ' .. first, 'DiagnosticWarn' } }
  end
  local chunks = {}
  local current = found.dep.version
  if found.aged then
    table.insert(chunks, {
      '  → ' .. M.format(found.aged.version, current),
      'DiagnosticHint',
    })
  end
  if found.held then
    table.insert(chunks, {
      ('  %s held, %s'):format(
        M.format(found.held.version, current),
        age(found.held.time)
      ),
      'Comment',
    })
  end
  if found.aged and found.dep.pinned then
    table.insert(chunks, { '  (pinned: :DyActionsPin)', 'Comment' })
  end
  return #chunks > 0 and chunks or nil
end

--- Clear what a check showed on `bufnr`
---@param bufnr? integer
function M.clear(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  vim.api.nvim_buf_clear_namespace(bufnr, M.ns, 0, -1)
  M.found[bufnr] = nil
end

--- Ask the registries about every dependency of the buffer and show, at the
--- end of each line, what it may move to
---@param bufnr? integer
---@param on_done? fun() Called once everything is shown, for the specs
function M.check(bufnr, on_done)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local reader = M.manifest(vim.api.nvim_buf_get_name(bufnr))
  if not reader then
    return notify(
      'Not a manifest read here: package.json, go.mod, requirements*.txt,'
        .. ' pyproject.toml, *.tf or a GitHub workflow',
      vim.log.levels.WARN
    )
  end
  local deps = M.deps(reader, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if #deps == 0 then return notify('No dependency with a version here') end
  if vim.fn.executable('curl') ~= 1 then
    return notify('curl is not installed', vim.log.levels.ERROR)
  end
  M.clear(bufnr)
  notify(('Asking about %d dependencies…'):format(#deps))
  -- A later check of the buffer takes over: what this one still hears of
  -- is dropped
  M.runs[bufnr] = (M.runs[bufnr] or 0) + 1
  local run = M.runs[bufnr]
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local marks, behind, held, failed = {}, 0, 0, 0
  M.found[bufnr] = marks
  --- Whether what this run heard may still go on the lines it read
  local function current()
    return vim.api.nvim_buf_is_valid(bufnr)
      and M.runs[bufnr] == run
      and vim.api.nvim_buf_get_changedtick(bufnr) == tick
  end
  system.each(deps, M.PARALLEL, function(dep, done)
    cached(dep, function(releases, err)
      local found = { dep = dep, err = err }
      if releases then
        found.aged, found.held = M.pick(dep.version, releases)
      end
      if found.err then failed = failed + 1 end
      if found.aged then behind = behind + 1 end
      if found.held then held = held + 1 end
      -- Each line as its registry answers, not when the slowest has
      local text = current() and virt_text(found)
      if text then
        local id = vim.api.nvim_buf_set_extmark(bufnr, M.ns, dep.line - 1, 0, {
          virt_text = text,
          virt_text_pos = 'eol',
        })
        marks[id] = found
      end
      done()
    end)
  end, function()
    if not vim.api.nvim_buf_is_valid(bufnr) or M.runs[bufnr] ~= run then
      if on_done then on_done() end
      return
    end
    -- The lines read may point elsewhere now
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      M.clear(bufnr)
      notify('The buffer changed meanwhile: check again', vim.log.levels.WARN)
      if on_done then on_done() end
      return
    end
    local summary = ('%d of %d dependencies behind a release out for %d days'):format(
      behind,
      #deps,
      math.floor(require('tools.lazy-quarantine').window() / 86400)
    )
    if held > 0 then
      summary = summary .. (', %d with newer ones held'):format(held)
    end
    if failed > 0 then summary = summary .. (', %d failed'):format(failed) end
    notify(summary, failed > 0 and vim.log.levels.WARN or nil)
    if on_done then on_done() end
  end)
end

--- Write the release shown on the line under the cursor into it
---@param bufnr? integer
function M.bump(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local row = vim.api.nvim_win_get_cursor(0)[1] - 1
  local found, id
  for _, mark in
    ipairs(
      vim.api.nvim_buf_get_extmarks(bufnr, M.ns, { row, 0 }, { row, -1 }, {})
    )
  do
    local candidate = (M.found[bufnr] or {})[mark[1]]
    if candidate and candidate.aged then
      found, id = candidate, mark[1]
      break
    end
  end
  if not found then
    return notify('Nothing to bump on this line: run :DyOutdated first')
  end
  if found.dep.pinned then
    return notify(
      'Pinned to a commit: move the tag, then pin it again with :DyActionsPin',
      vim.log.levels.WARN
    )
  end
  local line = vim.api.nvim_buf_get_lines(bufnr, row, row + 1, false)[1]
  local current = found.dep.version
  -- Where it was read, else the first place after the name: an edit before
  -- it moves it along the line
  local start = line:sub(found.dep.col, found.dep.col + #current - 1) == current
      and found.dep.col
    or line:find(current, 1, true)
  if not start then
    return notify(
      ('%s is no longer on this line'):format(current),
      vim.log.levels.WARN
    )
  end
  local release = M.format(found.aged.version, current)
  vim.api.nvim_buf_set_text(
    bufnr,
    row,
    start - 1,
    row,
    start - 1 + #current,
    { release }
  )
  vim.api.nvim_buf_del_extmark(bufnr, M.ns, id)
  M.found[bufnr][id] = nil
  notify(('%s: %s → %s'):format(found.dep.name, current, release))
end

M.SUBCOMMANDS = { 'bump', 'clear' }

--- `:DyOutdated [bump|clear]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.check(0) end
  if sub == 'bump' then return M.bump(0) end
  if sub == 'clear' then return M.clear(0) end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
