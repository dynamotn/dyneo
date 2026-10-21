--- A bill of materials for the editor, and the vulnerabilities known in it
---
--- Everything this configuration runs that it did not write comes from two
--- places: the plugins lazy.nvim cloned, each at the commit of the lockfile,
--- and the tools Mason installed, each at the version of its receipt. That
--- is a supply chain like any other, so it is listed like any other -- as a
--- CycloneDX document a scanner can read -- and asked about like any other,
--- of OSV (https://osv.dev), which knows the advisories of npm, PyPI,
--- crates.io, Go and the rest, and the commits of the repositories they name.
---
--- The quarantine in front of both (`tools.lazy-quarantine`,
--- `tools.mason-quarantine`) is about what is new; this is about what is
--- already here, and was found out about after it arrived.
local M = {}

--- The purl types OSV answers for, by the ecosystem they stand for
local OSV_TYPES = {
  npm = true,
  pypi = true,
  cargo = true,
  golang = true,
  gem = true,
  nuget = true,
  composer = true,
  maven = true,
  hex = true,
  pub = true,
}

--- Where OSV takes a batch of questions
M.OSV_URL = 'https://api.osv.dev/v1/querybatch'

---@class DySbomComponent
---@field name string
---@field version string A commit for a plugin, a release for a Mason package
---@field purl? string
---@field source 'lazy.nvim'|'mason'|'lockfile'
---@field file? string The lockfile it was read from
---@field line? integer Where in it, 1-based
---@field dir? string Where it is installed, for its license file
---@field license? string SPDX id or expression, when known

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

---@param text string
---@return string
local function decode(text)
  return (
    text:gsub(
      '%%(%x%x)',
      function(hex) return string.char(tonumber(hex, 16)) end
    )
  )
end

--- The forges a purl has a type of its own for
local FORGES = {
  ['github.com'] = 'github',
  ['gitlab.com'] = 'gitlab',
  ['bitbucket.org'] = 'bitbucket',
}

--- The purl of a plugin cloned from `url`, at `commit`
---
--- A forge purl names the repository; anything else is `generic`, with the
--- clone URL as its `vcs_url` so it can still be found.
---@param name string
---@param url? string
---@param commit string
---@return string
function M.plugin_purl(name, url, commit)
  local host, path
  if url then
    local rest = url:match('^%a[%w+.-]*://(.*)$')
    if rest then
      -- A user in the URL (`https://user@host/...`) is no part of the name
      host, path = rest:gsub('^[^@/]*@', ''):match('^([^/]+)/(.-)/?$')
    else
      host, path = url:match('^[%w_.-]+@([^:]+):(.-)/?$')
    end
  end
  if host and path then
    path = path:gsub('%.git$', '')
    local namespace, repo = path:match('^(.+)/([^/]+)$')
    local forge = FORGES[host:lower()]
    if forge and namespace then
      -- The purl spec lowercases both for GitHub and Bitbucket, and GitLab
      -- paths are case insensitive too
      return ('pkg:%s/%s/%s@%s'):format(
        forge,
        namespace:lower(),
        repo:lower(),
        commit
      )
    end
    return ('pkg:generic/%s@%s?vcs_url=%s'):format(
      encode(name),
      commit,
      encode('git+' .. url .. '@' .. commit)
    )
  end
  return ('pkg:generic/%s@%s'):format(encode(name), commit)
end

--- Read and decode the JSON file at `path`, or nil
---@param path string
---@return table?
local function read_json(path)
  local ok, lines = pcall(vim.fn.readfile, path)
  if not ok then return nil end
  local decoded, value = pcall(vim.json.decode, table.concat(lines, '\n'))
  return decoded and type(value) == 'table' and value or nil
end

--- The plugins of a lazy.nvim lockfile
---@param lockfile string
---@param urls table<string, string> Plugin name to the URL it was cloned from
---@param dirs? table<string, string> Plugin name to where it is cloned
---@return DySbomComponent[]
function M.plugins(lockfile, urls, dirs)
  local components = {}
  for name, entry in pairs(read_json(lockfile) or {}) do
    if type(entry) == 'table' and type(entry.commit) == 'string' then
      table.insert(components, {
        name = name,
        version = entry.commit,
        purl = M.plugin_purl(name, urls[name], entry.commit),
        source = 'lazy.nvim',
        dir = dirs and dirs[name],
      })
    end
  end
  return components
end

--- The packages Mason installed under `root`, from their receipts
---
--- The receipt keeps the purl the package was installed from, version and
--- all, which is the very thing a bill of materials wants.
---@param root string Mason's install root
---@return DySbomComponent[]
function M.mason(root)
  local components = {}
  local packages = vim.fs.joinpath(root, 'packages')
  for name, kind in vim.fs.dir(packages) do
    if kind == 'directory' then
      local receipt =
        read_json(vim.fs.joinpath(packages, name, 'mason-receipt.json'))
      local id = receipt and vim.tbl_get(receipt, 'source', 'id')
      if receipt and type(id) == 'string' then
        local purl = id:find('^pkg:') and id or nil
        local version = purl
            and purl:match('@([^?#]+)')
            and decode(purl:match('@([^?#]+)'))
          or 'unknown'
        table.insert(components, {
          name = receipt.name or name,
          version = version,
          purl = purl,
          source = 'mason',
          dir = vim.fs.joinpath(packages, name),
        })
      end
    end
  end
  return components
end

--- Everything installed on this machine: lazy.nvim's plugins and Mason's
--- packages, sorted by name
---@return DySbomComponent[]
function M.components()
  local components = {}

  local ok_config, Config = pcall(require, 'lazy.core.config')
  if ok_config and Config.options and Config.options.lockfile then
    local urls, dirs = {}, {}
    for name, plugin in pairs(Config.plugins or {}) do
      urls[name], dirs[name] = plugin.url, plugin.dir
    end
    vim.list_extend(components, M.plugins(Config.options.lockfile, urls, dirs))
  end

  local ok_settings, settings = pcall(require, 'mason.settings')
  local root = ok_settings and settings.current.install_root_dir
    or vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'mason')
  vim.list_extend(components, M.mason(root))

  table.sort(components, function(a, b)
    if a.name == b.name then return a.source < b.source end
    return a.name < b.name
  end)
  return components
end

--- What the text of a license says, in order: the first rule whose phrases
--- are all in it names it. A GPL names its version, and the later version
--- comes first, since "version 2" is in "version 2.1" too. The MPL and the
--- EPL come before the GPL family, which their bodies name as secondary
--- licenses.
local LICENSE_RULES = {
  { 'MPL-2.0', { 'mozilla public license', '2.0' } },
  { 'EPL-2.0', { 'eclipse public license', '2.0' } },
  { 'EPL-1.0', { 'eclipse public license', '1.0' } },
  { 'AGPL-3.0', { 'gnu affero general public license' } },
  {
    'LGPL-3.0',
    { 'gnu lesser general public license', 'version 3' },
  },
  {
    'LGPL-2.1',
    { 'gnu lesser general public license', 'version 2.1' },
  },
  -- The older name of the LGPL, whose text mentions the GPL too
  { 'LGPL-2.0', { 'gnu library general public license' } },
  { 'GPL-3.0', { 'gnu general public license', 'version 3' } },
  { 'GPL-2.0', { 'gnu general public license', 'version 2' } },
  { 'Apache-2.0', { 'apache license', 'version 2.0' } },
  { 'MIT', { 'permission is hereby granted, free of charge' } },
  {
    'BSD-3-Clause',
    { 'redistribution and use in source and binary forms', 'neither the name' },
  },
  { 'BSD-2-Clause', { 'redistribution and use in source and binary forms' } },
  {
    'ISC',
    {
      'permission to use, copy, modify, and/or distribute this software',
      'provided that the above copyright notice',
    },
  },
  {
    '0BSD',
    { 'permission to use, copy, modify, and/or distribute this software' },
  },
  {
    'Unlicense',
    {
      'this is free and unencumbered software released into the public domain',
    },
  },
  { 'WTFPL', { 'do what the fuck you want to' } },
  { 'CC0-1.0', { 'cc0 1.0' } },
  {
    'Zlib',
    { 'altered source versions must be plainly marked as such' },
  },
  { 'Vim', { 'vim license' } },
  { 'Vim', { 'same terms as vim' } },
}

--- Non-blank lines at the top of a license read as its title
M.LICENSE_TITLE_LINES = 3

--- The SPDX license `text` is, from a `SPDX-License-Identifier` line or else
--- from what it says; nil when it says nothing known
---@param text string
---@return string?
function M.detect_license(text)
  local spdx = text:match('SPDX%-License%-Identifier:%s*([^\n]-)%s*%*?/?%s*\n')
    or text:match('SPDX%-License%-Identifier:%s*([^\n]-)%s*$')
  if spdx and spdx ~= '' then return spdx end
  -- A license names itself in its title; its body may name others, as the
  -- GPLv2 does the Library GPL
  local head = {}
  for line in text:gmatch('[^\n]+') do
    if line:find('%S') then table.insert(head, line) end
    if #head == M.LICENSE_TITLE_LINES then break end
  end
  for _, part in ipairs({ table.concat(head, ' '), text }) do
    local plain = part:lower():gsub('%s+', ' ')
    for _, rule in ipairs(LICENSE_RULES) do
      local all = true
      for _, phrase in ipairs(rule[2]) do
        if not plain:find(phrase, 1, true) then
          all = false
          break
        end
      end
      if all then return rule[1] end
    end
  end
  return nil
end

--- Bytes of a license file read: the name and the phrases that tell it
--- apart are at its top
M.LICENSE_BYTES = 8192

--- The license of what is installed in `dir`, from its license file
---@param dir string
---@return string?
function M.license_of_dir(dir)
  local names = {}
  for name, kind in vim.fs.dir(dir) do
    local upper = name:upper()
    if
      kind == 'file'
      and (
        upper:match('^LICEN[CS]E')
        or upper:match('^COPYING')
        or upper:match('^UNLICENSE')
      )
    then
      table.insert(names, name)
    end
  end
  -- `LICENSE` before `LICENSE-APACHE`, so one file decides, the same each time
  table.sort(names)
  for _, name in ipairs(names) do
    local file = io.open(vim.fs.joinpath(dir, name), 'r')
    if file then
      local text = file:read(M.LICENSE_BYTES) or ''
      file:close()
      local license = M.detect_license(text)
      if license then return license end
    end
  end
  return nil
end

--- The licenses Mason's registry gives for package `name`, if it is loaded
---@param name string
---@return string[]?
local function mason_licenses(name)
  local ok, registry = pcall(require, 'mason-registry')
  if not ok then return nil end
  local found, package = pcall(registry.get_package, name)
  local licenses = found
    and package
    and vim.tbl_get(package, 'spec', 'licenses')
  return type(licenses) == 'table' and licenses or nil
end

--- `components` with the license of each: its license file, else -- for a
--- Mason package -- what the registry says
---@param components DySbomComponent[]
---@param registry? fun(name: string): string[]? Mason's, unless given
---@return DySbomComponent[]
function M.with_licenses(components, registry)
  registry = registry or mason_licenses
  for _, component in ipairs(components) do
    if not component.license and component.dir then
      component.license = M.license_of_dir(component.dir)
    end
    if not component.license and component.source == 'mason' then
      local licenses = registry(component.name)
      if licenses and #licenses > 0 then
        component.license = table.concat(licenses, ' AND ')
      end
    end
  end
  return components
end

--- Whether a license of `expression` is one of `ids`, a trailing `*` in one
--- matching any version: `AGPL-*` matches `MIT OR AGPL-3.0`
---@param expression string
---@param ids string[]
---@return boolean
function M.license_matches(expression, ids)
  for token in expression:gmatch('[%w%.%-%+]+') do
    for _, id in ipairs(ids) do
      local prefix = id:match('^(.-)%*$')
      if
        token == id
        or (prefix and token:sub(1, #prefix) == prefix and #token > #prefix)
      then
        return true
      end
    end
  end
  return false
end

--- The report of the licenses of `components` under `policy`: the denied,
--- those to review and the unknown first, then how many of each license
---@param components DySbomComponent[]
---@param policy DyLicensePolicy
---@return string[] lines
---@return { deny: integer, review: integer, unknown: integer, total: integer }
function M.license_report(components, policy)
  local groups = { deny = {}, review = {}, unknown = {} }
  local tally = {}
  for _, component in ipairs(components) do
    local label = ('%s %s (%s)'):format(
      component.name,
      component.version:sub(1, 12),
      component.source
    )
    local license = component.license
    if not license then
      table.insert(groups.unknown, '- ' .. label)
    else
      tally[license] = (tally[license] or 0) + 1
      local item = ('- %s: %s'):format(label, license)
      if M.license_matches(license, policy.deny or {}) then
        table.insert(groups.deny, item)
      elseif M.license_matches(license, policy.review or {}) then
        table.insert(groups.review, item)
      end
    end
  end
  local lines = {
    '# Licenses',
    '',
    ('%d plugins and packages: %d denied, %d to review, %d unknown.'):format(
      #components,
      #groups.deny,
      #groups.review,
      #groups.unknown
    ),
    'Denied and reviewed as `DyNeo.license_policy` says.',
  }
  for _, section in ipairs({
    { 'deny', 'Denied' },
    { 'review', 'To review' },
    { 'unknown', 'Unknown' },
  }) do
    if #groups[section[1]] > 0 then
      vim.list_extend(lines, { '', '## ' .. section[2], '' })
      vim.list_extend(lines, groups[section[1]])
    end
  end
  local names = vim.tbl_keys(tally)
  table.sort(names, function(a, b)
    if tally[a] ~= tally[b] then return tally[a] > tally[b] end
    return a < b
  end)
  vim.list_extend(
    lines,
    { '', '## By license', '', '| License | Count |', '| --- | ---: |' }
  )
  for _, name in ipairs(names) do
    table.insert(lines, ('| %s | %d |'):format(name, tally[name]))
  end
  return lines,
    {
      deny = #groups.deny,
      review = #groups.review,
      unknown = #groups.unknown,
      total = #components,
    }
end

--- A random version 4 UUID, for the serial number of a document
---@return string
local function uuid()
  local bytes = { vim.uv.random(16):byte(1, 16) }
  bytes[7] = bit.bor(bit.band(bytes[7], 0x0f), 0x40)
  bytes[9] = bit.bor(bit.band(bytes[9], 0x3f), 0x80)
  local hex = vim.tbl_map(
    function(byte) return ('%02x'):format(byte) end,
    bytes
  )
  return table.concat({
    table.concat(hex, '', 1, 4),
    table.concat(hex, '', 5, 6),
    table.concat(hex, '', 7, 8),
    table.concat(hex, '', 9, 10),
    table.concat(hex, '', 11, 16),
  }, '-')
end

--- The CycloneDX 1.5 document listing `components`
---@param components DySbomComponent[]
---@param now? integer Seconds since the epoch, for the specs
---@return table
function M.bom(components, now)
  return {
    bomFormat = 'CycloneDX',
    specVersion = '1.5',
    serialNumber = 'urn:uuid:' .. uuid(),
    version = 1,
    metadata = {
      timestamp = os.date('!%Y-%m-%dT%H:%M:%SZ', now or os.time()),
      component = {
        type = 'application',
        name = 'DyNeo',
        ['bom-ref'] = 'dyneo',
      },
    },
    components = vim.tbl_map(function(component)
      return {
        type = 'library',
        ['bom-ref'] = component.purl
          or (component.source .. ':' .. component.name),
        name = component.name,
        version = component.version,
        purl = component.purl,
        -- An id alone, an expression -- `MIT OR Apache-2.0` -- as one
        licenses = component.license and {
          component.license:find('%s') and {
            expression = component.license,
          } or { license = { id = component.license } },
        } or nil,
        properties = {
          { name = 'dyneo:installed-by', value = component.source },
        },
      }
    end, components),
  }
end

--- `value` as indented JSON, when this Neovim can indent it
---@param value table
---@return string
local function to_json(value)
  local ok, json =
    pcall(vim.json.encode, value, { indent = '  ', sort_keys = true })
  return ok and json or vim.json.encode(value)
end

--- What to ask OSV, one question per component it can answer for
---
--- A package is asked about by its purl. A plugin has no ecosystem in OSV,
--- but a commit does: OSV maps the commits of a repository an advisory
--- names onto the ranges it affects.
---@param components DySbomComponent[]
---@return table[] queries
---@return DySbomComponent[] asked The component behind each query
function M.osv_queries(components)
  local queries, asked = {}, {}
  for _, component in ipairs(components) do
    local type = component.purl and component.purl:match('^pkg:([^/]+)/')
    if type and OSV_TYPES[type] then
      table.insert(queries, { package = { purl = component.purl } })
      table.insert(asked, component)
    elseif
      component.source == 'lazy.nvim' and component.version:find('^%x+$')
    then
      table.insert(queries, { commit = component.version })
      table.insert(asked, component)
    end
  end
  return queries, asked
end

---@class DySbomVulnerable
---@field component DySbomComponent
---@field ids string[]

--- The components OSV knows a vulnerability of
---
--- An answer without a result for every question is an error, not a clean
--- bill: the results are matched to the questions by position, and the ones
--- missing would read as "nothing known".
---@param asked DySbomComponent[] In the order the queries were sent
---@param response table The decoded answer of the batch query
---@return DySbomVulnerable[]? findings
---@return string? err
function M.osv_findings(asked, response)
  local results = response.results
  if type(results) ~= 'table' or #results ~= #asked then
    return nil,
      ('OSV answered %d results for %d questions'):format(
        type(results) == 'table' and #results or 0,
        #asked
      )
  end
  local findings = {}
  for index, result in ipairs(results) do
    local ids = vim.tbl_map(
      function(vuln) return vuln.id end,
      result.vulns or {}
    )
    if #ids > 0 and asked[index] then
      table.sort(ids)
      table.insert(findings, { component = asked[index], ids = ids })
    end
  end
  return findings
end

--- The report of `findings`, as Markdown lines
---@param findings DySbomVulnerable[]
---@param asked integer How many components were asked about
---@param total integer How many there are
---@return string[]
function M.osv_report(findings, asked, total)
  local lines = {
    ('# Known vulnerabilities: %d'):format(#findings),
    '',
    (
      '%d of %d plugins and packages asked of OSV; the rest have no '
      .. 'ecosystem it covers.'
    ):format(asked, total),
  }
  if #findings > 0 then table.insert(lines, '') end
  for _, finding in ipairs(findings) do
    local component = finding.component
    table.insert(
      lines,
      ('## %s %s (%s)'):format(
        component.name,
        component.version:sub(1, 12),
        component.source
      )
    )
    table.insert(lines, '')
    for _, id in ipairs(finding.ids) do
      table.insert(
        lines,
        ('- %s https://osv.dev/vulnerability/%s'):format(id, id)
      )
    end
    table.insert(lines, '')
  end
  return lines
end

--- A component read out of a lockfile
---@param kind string purl type
---@param name string
---@param version string
---@param file string
---@param line integer
---@return DySbomComponent
local function locked(kind, name, version, file, line)
  local path = vim.tbl_map(encode, vim.split(name, '/', { plain = true }))
  return {
    name = name,
    version = version,
    purl = ('pkg:%s/%s@%s'):format(
      kind,
      table.concat(path, '/'),
      encode(version)
    ),
    source = 'lockfile',
    file = file,
    line = line,
  }
end

--- The packages of the `[[package]]` tables of a TOML lockfile
--- (`Cargo.lock`, `uv.lock`, `poetry.lock`), each at its `name` line. A
--- package of the project itself is left out: it has no `source` in
--- `Cargo.lock`, and an `editable`, `virtual` or `directory` one in `uv.lock`.
---@param lines string[]
---@param need_source boolean Leave out a package without `source`
---@return { name: string, version: string, line: integer }[]
local function toml_packages(lines, need_source)
  local packages, current = {}, nil
  local function close()
    if
      current
      and current.name
      and current.version
      and not current.local_source
      and (current.source or not need_source)
    then
      table.insert(packages, current)
    end
    current = nil
  end
  for number, line in ipairs(lines) do
    if line:match('^%[%[package%]%]%s*$') then
      close()
      current = {}
    elseif line:match('^%[') then
      -- Any other table ends the package and is not one
      close()
    elseif current then
      local key, value = line:match('^([%w_]+)%s*=%s*(.-)%s*$')
      if key == 'name' and not current.name then
        current.name = value:match('^"(.*)"$')
        current.line = number
      elseif key == 'version' and not current.version then
        current.version = value:match('^"(.*)"$')
      elseif key == 'source' then
        current.source = true
        if
          value:match('editable%s*=')
          or value:match('virtual%s*=')
          or value:match('directory%s*=')
        then
          current.local_source = true
        end
      end
    end
  end
  close()
  return packages
end

--- A Python package name as PyPI and OSV compare it
---@param name string
---@return string
local function pypi_name(name) return (name:lower():gsub('[%._]+', '-')) end

--- How each lockfile is read, by its name
---@type table<string, fun(lines: string[], file: string): DySbomComponent[]>
M.LOCKFILES = {
  ['go.mod'] = function(lines, file)
    local components, in_block = {}, false
    for number, line in ipairs(lines) do
      local code = line:gsub('//.*$', '')
      local module, version
      if code:match('^%s*require%s*%(') then
        in_block = true
      elseif in_block and code:match('^%s*%)') then
        in_block = false
      elseif in_block then
        module, version = code:match('^%s*(%S+)%s+(v%S+)')
      else
        module, version = code:match('^%s*require%s+(%S+)%s+(v%S+)')
      end
      if module then
        table.insert(
          components,
          locked('golang', module, version, file, number)
        )
      end
    end
    return components
  end,
  ['Cargo.lock'] = function(lines, file)
    return vim.tbl_map(
      function(p) return locked('cargo', p.name, p.version, file, p.line) end,
      toml_packages(lines, true)
    )
  end,
  ['uv.lock'] = function(lines, file)
    return vim.tbl_map(
      function(p)
        return locked('pypi', pypi_name(p.name), p.version, file, p.line)
      end,
      toml_packages(lines, false)
    )
  end,
  ['poetry.lock'] = function(lines, file)
    return vim.tbl_map(
      function(p)
        return locked('pypi', pypi_name(p.name), p.version, file, p.line)
      end,
      toml_packages(lines, false)
    )
  end,
  -- npm 7 and later (lockfile v2 and v3): `packages` keyed by the path
  -- under `node_modules`, the last part of which is the package
  ['package-lock.json'] = function(lines, file)
    local ok, lock = pcall(
      vim.json.decode,
      table.concat(lines, '\n'),
      { luanil = { object = true, array = true } }
    )
    if not ok or type(lock) ~= 'table' or type(lock.packages) ~= 'table' then
      return {}
    end
    -- Where each key starts: the JSON says what, the text says where
    local where = {}
    for number, line in ipairs(lines) do
      local key = line:match('^%s*"(node_modules/[^"]+)"%s*:')
      if key and not where[key] then where[key] = number end
    end
    local components = {}
    for key, entry in pairs(lock.packages) do
      local name = key:match('.*node_modules/(.+)$')
      if
        name
        and type(entry) == 'table'
        and type(entry.version) == 'string'
        and not entry.link
      then
        table.insert(
          components,
          locked('npm', name, entry.version, file, where[key] or 1)
        )
      end
    end
    table.sort(components, function(a, b) return a.line < b.line end)
    return components
  end,
}

--- The components of the lockfile at `file`, or nil for a name not known
---@param file string
---@param lines? string[] Its lines, read from disk unless given
---@return DySbomComponent[]?
function M.lockfile(file, lines)
  local parse = M.LOCKFILES[vim.fs.basename(file)]
  if not parse then return nil end
  if not lines then
    local ok, read = pcall(vim.fn.readfile, file)
    lines = ok and read or {}
  end
  return parse(lines, file)
end

--- Hand `on_files` the lockfiles of the project at `root`: those git
--- tracks, else those at its top -- outside git, or not tracked yet. Walking
--- the tree would go through `node_modules` and `vendor`. A list cut at
--- the output cap is no list: `on_files` gets nil and why.
---@param root string
---@param on_files fun(files: string[]?, err: string?)
function M.find_lockfiles(root, on_files)
  local names = vim.tbl_keys(M.LOCKFILES)
  table.sort(names)
  local patterns = {}
  for _, name in ipairs(names) do
    vim.list_extend(patterns, { name, '**/' .. name })
  end
  --- The lockfiles at the top of `root` only, when git cannot list them
  local function at_top()
    local files = {}
    for _, name in ipairs(names) do
      local file = vim.fs.joinpath(root, name)
      if vim.fn.filereadable(file) == 1 then table.insert(files, file) end
    end
    on_files(files)
  end
  require('util.system').run(
    vim.list_extend({ 'git', 'ls-files', '-z', '--' }, patterns),
    { cwd = root, timeout = 10000 },
    function(result)
      if result.cut then
        return on_files(
          nil,
          'git ls-files printed more than can be read, and was stopped'
        )
      end
      if result.code ~= 0 then return at_top() end
      local files = {}
      for _, path in
        ipairs(vim.split(result.stdout or '', '\0', { trimempty = true }))
      do
        local file = vim.fs.joinpath(root, path)
        if vim.fn.filereadable(file) == 1 then table.insert(files, file) end
      end
      if #files == 0 then return at_top() end
      on_files(files)
    end
  )
end

local ns = vim.api.nvim_create_namespace('dy_sbom')

--- Show `findings` of lockfiles as warnings on the line of each package, and
--- in the quickfix list
---@param findings DySbomVulnerable[]
---@param title string
function M.show_findings(findings, title)
  vim.diagnostic.reset(ns)
  local per_buffer, items = {}, {}
  for _, finding in ipairs(findings) do
    local component = finding.component
    local text = ('%s %s: %s'):format(
      component.name,
      component.version,
      table.concat(finding.ids, ', ')
    )
    if component.file then
      local bufnr = vim.fn.bufadd(component.file)
      per_buffer[bufnr] = per_buffer[bufnr] or {}
      table.insert(per_buffer[bufnr], {
        lnum = (component.line or 1) - 1,
        col = 0,
        message = text,
        severity = vim.diagnostic.severity.WARN,
        source = 'osv',
        code = finding.ids[1],
      })
    end
    table.insert(items, {
      filename = component.file,
      lnum = component.line or 1,
      text = text,
      type = 'W',
    })
  end
  for bufnr, diagnostics in pairs(per_buffer) do
    vim.diagnostic.set(ns, bufnr, diagnostics)
  end
  vim.fn.setqflist({}, ' ', { title = title, items = items })
end

--- Most questions OSV takes in one batch
M.OSV_BATCH = 1000

--- Most bytes of one OSV answer read
M.MAX_OSV_ANSWER = 32 * 1024 * 1024

--- Ask OSV about `queries` in batches, one after the other
---@param queries table[]
---@param asked DySbomComponent[]
---@param on_done fun(findings: DySbomVulnerable[]?, err: string?)
function M.ask_osv(queries, asked, on_done)
  local findings = {}
  local function batch(first)
    if first > #queries then return on_done(findings) end
    local last = math.min(first + M.OSV_BATCH - 1, #queries)
    require('util.system').run({
      'curl',
      '--silent',
      '--show-error',
      '--fail',
      '--max-time',
      '60',
      '--header',
      'Content-Type: application/json',
      '--data-binary',
      '@-',
      M.OSV_URL,
    }, {
      timeout = 90000,
      max_bytes = M.MAX_OSV_ANSWER,
      stdin = vim.json.encode({
        queries = vim.list_slice(queries, first, last),
      }),
    }, function(result)
      if result.code ~= 0 or result.cut then
        return on_done(
          nil,
          'OSV query failed: '
            .. (
              result.cut and 'an answer larger than can be read'
              or require('util.system').failure(result, 'curl')
            )
        )
      end
      local ok, response = pcall(vim.json.decode, result.stdout or '')
      if not ok or type(response) ~= 'table' then
        return on_done(nil, 'OSV answered with something that is not JSON')
      end
      local found, err =
        M.osv_findings(vim.list_slice(asked, first, last), response)
      if not found then return on_done(nil, err) end
      vim.list_extend(findings, found)
      batch(last + 1)
    end)
  end
  batch(1)
end

--- A scratch buffer holding `lines`, in a tab of its own
---@param lines string[]
---@param filetype string
local function scratch(lines, filetype)
  require('util.scratch').open(lines, { filetype = filetype })
end

local notify = require('util.notify').titled('SBOM')

--- Ask OSV about every component, and show what it knows
---
--- One request, the names and versions of what is installed and the commits
--- of the plugins, nothing else of the machine.
function M.osv()
  local components = M.components()
  local queries, asked = M.osv_queries(components)
  if #queries == 0 then return notify('Nothing to ask OSV about') end
  if vim.fn.executable('curl') ~= 1 then
    return notify('curl is not installed', vim.log.levels.ERROR)
  end
  notify(('Asking OSV about %d plugins and packages…'):format(#queries))
  M.ask_osv(queries, asked, function(findings, err)
    if not findings then return notify(err, vim.log.levels.ERROR) end
    if #findings == 0 then
      return notify(
        ('No known vulnerabilities in the %d plugins and packages asked'):format(
          #asked
        )
      )
    end
    scratch(M.osv_report(findings, #asked, #components), 'markdown')
  end)
end

--- Ask OSV about the packages of the project's lockfiles, and show what it
--- knows on the line of each
---
--- The lockfile of the current buffer if it is one, else every lockfile of
--- the project. Only names and versions leave the machine.
function M.lock()
  local name = vim.api.nvim_buf_get_name(0)
  if name ~= '' and M.LOCKFILES[vim.fs.basename(name)] then
    return M.ask_lockfiles({ name })
  end
  local root = vim.fs.root(0, { '.git' }) or vim.uv.cwd() --[[@as string]]
  M.find_lockfiles(root, M.ask_lockfiles)
end

--- Ask OSV about the packages of `files`, and show what it knows
---@param files string[]?
---@param err? string Why there is no list of them
function M.ask_lockfiles(files, err)
  if not files then
    return notify(
      'Could not list the lockfiles: ' .. (err or 'no reason given'),
      vim.log.levels.ERROR
    )
  end
  if #files == 0 then
    return notify(
      'No lockfile found: '
        .. table.concat(vim.tbl_keys(M.LOCKFILES), ', ')
        .. ' are read'
    )
  end

  local components = {}
  for _, file in ipairs(files) do
    local bufnr = vim.fn.bufnr(file)
    -- An open buffer may be ahead of the file
    local lines = bufnr ~= -1
        and vim.api.nvim_buf_is_loaded(bufnr)
        and vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      or nil
    vim.list_extend(components, M.lockfile(file, lines) or {})
  end
  local queries, asked = M.osv_queries(components)
  if #queries == 0 then
    return notify('No package in ' .. #files .. ' lockfiles')
  end
  if vim.fn.executable('curl') ~= 1 then
    return notify('curl is not installed', vim.log.levels.ERROR)
  end
  notify(
    ('Asking OSV about %d packages of %d lockfiles…'):format(#queries, #files)
  )
  M.ask_osv(queries, asked, function(findings, osv_err)
    if not findings then return notify(osv_err, vim.log.levels.ERROR) end
    local summary = ('%d of %d packages with known vulnerabilities'):format(
      #findings,
      #asked
    )
    M.show_findings(findings, 'OSV: ' .. summary)
    notify(summary, #findings > 0 and vim.log.levels.WARN or nil)
  end)
end

--- Show the license of every plugin and Mason package, the ones
--- `DyNeo.license_policy` denies or flags, and those not known, first
function M.license()
  local components = M.with_licenses(M.components())
  if #components == 0 then
    return notify('Nothing installed to read the licenses of')
  end
  local policy = (rawget(_G, 'DyNeo') or {}).license_policy
    or { deny = {}, review = {} }
  local lines, counts = M.license_report(components, policy)
  scratch(lines, 'markdown')
  notify(
    ('%d denied, %d to review, %d unknown of %d'):format(
      counts.deny,
      counts.review,
      counts.unknown,
      counts.total
    ),
    counts.deny > 0 and vim.log.levels.ERROR
      or (counts.review + counts.unknown > 0 and vim.log.levels.WARN)
      or nil
  )
end

M.SUBCOMMANDS = { 'osv', 'lock', 'license' }

--- `:DySbom [{path}]`, `:DySbom osv`, `:DySbom lock`, `:DySbom license`
---@param args { fargs: string[] }
function M.command(args)
  local target = args.fargs[1]
  if target == 'osv' then return M.osv() end
  if target == 'lock' then return M.lock() end
  if target == 'license' then return M.license() end

  local components = M.with_licenses(M.components())
  local json = to_json(M.bom(components))
  if not target then return scratch(vim.split(json, '\n'), 'json') end
  local path = vim.fn.fnamemodify(vim.fn.expand(target), ':p')
  if
    vim.uv.fs_stat(path)
    and vim.fn.confirm(
        ('Overwrite %s?'):format(vim.fn.fnamemodify(path, ':~')),
        '&Overwrite\n&Cancel',
        2
      )
      ~= 1
  then
    return notify('Not written', vim.log.levels.WARN)
  end
  vim.fn.mkdir(vim.fs.dirname(path), 'p')
  vim.fn.writefile(vim.split(json, '\n'), path)
  notify(('%d plugins and packages written to %s'):format(#components, path))
end

return M
