--- The licenses of a project's dependencies, against a policy
---
--- A GPL or AGPL package deep in a dependency tree is easy to miss and hard
--- to take out once shipped. trivy lists every package the project's
--- lockfiles name, each with the license its registry gave, as a CycloneDX
--- SBOM; each license expression is weighed against `M.POLICY` and the
--- project's own `.nvim/licenses.json`, and what is denied or to review is
--- listed, each package on the manifest line that brings it in.
---
--- `:DySbom` is about the editor's own plugins and packages; this is about
--- the project being edited. It reads the lockfiles the way `:DySbom lock`
--- does, to find the line of a package no manifest names.
local M = {}

local notify = require('util.notify').titled('Licenses')

---@alias DyLicenseVerdict 'allow'|'warn'|'deny'

---@class DyLicenseRules
---@field allow? string[] SPDX ids; a trailing `*` matches any version
---@field warn? string[]
---@field deny? string[]

--- The policy every project starts from. An id in none of the lists, and a
--- package with no license known, is to review. MPL-2.0 and the LGPL are
--- weak copyleft: allowed with conditions someone should read.
---@type DyLicenseRules
M.POLICY = {
  allow = {
    'MIT',
    'Apache-2.0',
    'BSD-2-Clause',
    'BSD-3-Clause',
    'ISC',
    '0BSD',
    'Unlicense',
    'Zlib',
    'CC0-1.0',
    'Python-2.0',
    'BlueOak-1.0.0',
  },
  warn = { 'MPL-2.0', 'LGPL-*' },
  deny = {
    'GPL-*',
    'AGPL-*',
    'SSPL-1.0',
    'BUSL-1.1',
    'Commons-Clause',
  },
}

--- The file a project overrides the policy with, relative to its root
M.FILE = '.nvim/licenses.json'

--- Milliseconds trivy may take on the project
M.TIMEOUT = 300000

--- Most bytes of an SBOM read
M.MAX_SBOM = 64 * 1024 * 1024

local RANK = { allow = 1, warn = 2, deny = 3 }
local VERDICT = { 'allow', 'warn', 'deny' }

---@param id string
---@param patterns string[]
---@return boolean
local function matches(id, patterns)
  for _, pattern in ipairs(patterns) do
    local wanted = pattern:lower()
    local prefix = wanted:match('^(.-)%*$')
    if id == wanted or (prefix and vim.startswith(id, prefix)) then
      return true
    end
  end
  return false
end

--- The verdict on one license id (`X WITH exception` is one id): the
--- project's rules first, then `M.POLICY`, deny before warn before allow
---@param id string
---@param project? DyLicenseRules
---@return DyLicenseVerdict
function M.classify(id, project)
  id = vim.trim(id):lower()
  if id == '' or id == 'noassertion' or id == 'none' then return 'warn' end
  for _, rules in ipairs({ project or {}, M.POLICY }) do
    for _, verdict in ipairs({ 'deny', 'warn', 'allow' }) do
      if matches(id, rules[verdict] or {}) then return verdict end
    end
  end
  return 'warn'
end

--- The verdict on an SPDX expression: `A OR B` passes if either does, `A AND
--- B` needs both, `WITH` binds an exception to its license, and parentheses
--- group. Text that is no expression -- a license name with spaces, as
--- CycloneDX's `license.name` may be -- is weighed as one id.
---@param expression? string
---@param project? DyLicenseRules
---@return DyLicenseVerdict
function M.evaluate(expression, project)
  if not expression then return 'warn' end
  local tokens = {}
  for token in expression:gsub('[()]', ' %0 '):gmatch('%S+') do
    table.insert(tokens, token)
  end
  local pos = 1
  local function peek() return tokens[pos] and tokens[pos]:upper() end
  local disjunction
  local function atom()
    local token = tokens[pos]
    if token == '(' then
      pos = pos + 1
      local rank = disjunction()
      if tokens[pos] ~= ')' then return nil end
      pos = pos + 1
      return rank
    end
    if not token or token == ')' then return nil end
    local upper = token:upper()
    if upper == 'AND' or upper == 'OR' or upper == 'WITH' then return nil end
    pos = pos + 1
    if peek() == 'WITH' and tokens[pos + 1] then
      token = token .. ' WITH ' .. tokens[pos + 1]
      pos = pos + 2
    end
    return RANK[M.classify(token, project)]
  end
  local function conjunction()
    local rank = atom()
    while rank and peek() == 'AND' do
      pos = pos + 1
      local other = atom()
      rank = other and math.max(rank, other)
    end
    return rank
  end
  disjunction = function()
    local rank = conjunction()
    while rank and peek() == 'OR' do
      pos = pos + 1
      local other = conjunction()
      rank = other and math.min(rank, other)
    end
    return rank
  end
  local rank = disjunction()
  if rank and pos > #tokens then return VERDICT[rank] end
  return M.classify(expression, project)
end

---@class DyLicensePackage
---@field name string
---@field version string
---@field purl string
---@field licenses string[] Each an id, a name or an expression, all to hold

--- The packages of a CycloneDX or SPDX JSON document; only those with a
--- purl are packages, the rest are the lockfiles and the project itself
---@param sbom table
---@return DyLicensePackage[]? packages
---@return string? err
function M.packages(sbom)
  local packages = {}
  if sbom.bomFormat == 'CycloneDX' then
    for _, component in ipairs(sbom.components or {}) do
      if type(component.purl) == 'string' then
        local licenses = {}
        for _, entry in ipairs(component.licenses or {}) do
          local text = entry.expression
            or vim.tbl_get(entry, 'license', 'id')
            or vim.tbl_get(entry, 'license', 'name')
          if type(text) == 'string' then table.insert(licenses, text) end
        end
        table.insert(packages, {
          name = (component.group and component.group ~= '')
              and (component.group .. '/' .. component.name)
            or component.name,
          version = component.version or '',
          purl = component.purl,
          licenses = licenses,
        })
      end
    end
  elseif type(sbom.spdxVersion) == 'string' then
    for _, item in ipairs(sbom.packages or {}) do
      local purl
      for _, ref in ipairs(item.externalRefs or {}) do
        if ref.referenceType == 'purl' then purl = ref.referenceLocator end
      end
      if type(purl) == 'string' then
        local licenses = {}
        for _, field in ipairs({ 'licenseConcluded', 'licenseDeclared' }) do
          local text = item[field]
          if
            type(text) == 'string'
            and text ~= 'NOASSERTION'
            and text ~= 'NONE'
          then
            licenses = { text }
            break
          end
        end
        table.insert(packages, {
          name = item.name,
          version = item.versionInfo or '',
          purl = purl,
          licenses = licenses,
        })
      end
    end
  else
    return nil, 'neither a CycloneDX nor an SPDX document'
  end
  return packages
end

--- The project's rules from `M.FILE` under `root`: nil when there is none,
--- or why it cannot be used. The file is data, only ever decoded as JSON.
---@param root string
---@return DyLicenseRules? rules
---@return string? err
function M.project_rules(root)
  local file = vim.fs.joinpath(root, M.FILE)
  if not vim.uv.fs_stat(file) then return nil end
  local ok, lines = pcall(vim.fn.readfile, file)
  local decoded, data =
    pcall(vim.json.decode, ok and table.concat(lines, '\n') or '')
  if not decoded or type(data) ~= 'table' or vim.islist(data) then
    return nil, M.FILE .. ' is not a JSON object'
  end
  local rules = {}
  for key, list in pairs(data) do
    if not RANK[key] then
      return nil, ('%s: unknown key `%s`'):format(M.FILE, key)
    end
    if type(list) ~= 'table' or not vim.islist(list) then
      return nil, ('%s: `%s` is not a list'):format(M.FILE, key)
    end
    for _, id in ipairs(list) do
      if type(id) ~= 'string' then
        return nil,
          ('%s: `%s` holds something not a string'):format(M.FILE, key)
      end
    end
    rules[key] = list
  end
  return rules
end

--- Where each kind of package is declared, and its lockfiles, by purl type
local MANIFESTS = {
  npm = { 'package.json', 'package-lock.json' },
  golang = { 'go.mod' },
  cargo = { 'Cargo.toml', 'Cargo.lock' },
  pypi = { 'pyproject.toml', 'requirements.txt', 'uv.lock', 'poetry.lock' },
}

---@param name string
---@return string
local function pypi_name(name) return (name:lower():gsub('[%._]+', '-')) end

--- The names a manifest line declares, as each kind compares them
---@type table<string, fun(line: string): string[]>
local DECLARES = {
  ['package.json'] = function(line) return { line:match('^%s*"([^"]+)"%s*:') } end,
  ['Cargo.toml'] = function(line)
    return {
      line:match('^%s*([%w_%-]+)%s*=')
        or line:match('^%s*%[[%w%.%-]*dependencies%.([%w_%-]+)%]'),
    }
  end,
  ['pyproject.toml'] = function(line)
    -- PEP 621 lists (`"requests>=2"`) and Poetry tables (`requests = "^2"`)
    local names = { line:match('^%s*([%w%._%-]+)%s*=') }
    for name in line:gmatch('"([%w%._%-]+)') do
      table.insert(names, name)
    end
    return vim.tbl_map(pypi_name, names)
  end,
  ['requirements.txt'] = function(line)
    local name = line:match('^%s*([%w%._%-]+)')
    return { name and pypi_name(name) }
  end,
}

--- The type and name of a purl, decoded: `pkg:npm/%40scope/x@1` is
--- `npm`, `@scope/x`
---@param purl string
---@return string? kind
---@return string? name
function M.purl_name(purl)
  local kind, path = purl:match('^pkg:([^/]+)/([^@?#]+)')
  if not kind then return nil end
  local name = vim.uri_decode(path)
  if kind == 'pypi' then name = pypi_name(name) end
  return kind, name
end

--- Where `item` is declared under `root`: the manifest line naming it, else
--- its lockfile entry, else the first manifest of its kind found
---
--- shortcut: only the manifests at the root are read; a package of a
--- workspace member points at the root, until monorepos need better.
---@param root string
---@param item DyLicensePackage
---@param cache table<string, string[]|false> Lines of each file read
---@return { filename: string, lnum: integer }?
function M.locate(root, item, cache)
  local kind, name = M.purl_name(item.purl)
  local files = kind and MANIFESTS[kind]
  if not files then return nil end
  local function lines_of(file)
    if cache[file] == nil then
      local ok, lines = pcall(vim.fn.readfile, file)
      cache[file] = ok and lines or false
    end
    return cache[file]
  end
  local first
  for _, base in ipairs(files) do
    local file = vim.fs.joinpath(root, base)
    local lines = lines_of(file)
    if lines then
      first = first or file
      local declares = DECLARES[base]
      local found
      if declares then
        for number, line in ipairs(lines) do
          if vim.list_contains(declares(line), name) then
            found = number
            break
          end
        end
      else
        -- A lockfile, read as `:DySbom lock` does
        for _, locked in
          ipairs(require('tools.sbom').lockfile(file, lines) or {})
        do
          local locked_name = kind == 'pypi' and pypi_name(locked.name)
            or locked.name
          if
            locked_name == name
            and (not found or locked.version == item.version)
          then
            found = locked.line
          end
        end
      end
      if found then return { filename = file, lnum = found } end
    end
  end
  return first and { filename = first, lnum = 1 } or nil
end

---@class DyLicenseFinding
---@field item DyLicensePackage
---@field verdict DyLicenseVerdict
---@field license string As shown: the licenses joined, or `unknown`

--- The verdict on each package
---@param packages DyLicensePackage[]
---@param project? DyLicenseRules
---@return DyLicenseFinding[]
function M.check(packages, project)
  local findings = {}
  for _, item in ipairs(packages) do
    -- Several licenses on one package all hold
    local rank = #item.licenses == 0 and RANK.warn or RANK.allow
    for _, license in ipairs(item.licenses) do
      rank = math.max(rank, RANK[M.evaluate(license, project)])
    end
    table.insert(findings, {
      item = item,
      verdict = VERDICT[rank],
      license = #item.licenses > 0 and table.concat(item.licenses, ' AND ')
        or 'unknown',
    })
  end
  table.sort(findings, function(a, b) return a.item.name < b.item.name end)
  return findings
end

--- The report of `findings`, as Markdown lines, and the count of each verdict
---@param findings DyLicenseFinding[]
---@param header string[] Lines saying what was read and the policy
---@return string[] lines
---@return table<DyLicenseVerdict, integer> counts
function M.report(findings, header)
  local groups = { allow = {}, warn = {}, deny = {} }
  for _, finding in ipairs(findings) do
    table.insert(groups[finding.verdict], finding)
  end
  local lines = {
    '# Licenses',
    '',
    ('%d packages: %d denied, %d to review, %d allowed.'):format(
      #findings,
      #groups.deny,
      #groups.warn,
      #groups.allow
    ),
  }
  vim.list_extend(lines, header)
  for _, section in ipairs({ { 'deny', 'Denied' }, { 'warn', 'To review' } }) do
    if #groups[section[1]] > 0 then
      vim.list_extend(lines, { '', '## ' .. section[2], '' })
      for _, finding in ipairs(groups[section[1]]) do
        table.insert(
          lines,
          ('- %s %s: %s `%s`'):format(
            finding.item.name,
            finding.item.version,
            finding.license,
            finding.item.purl
          )
        )
      end
    end
  end
  if #groups.allow > 0 then
    local tally = {}
    for _, finding in ipairs(groups.allow) do
      tally[finding.license] = (tally[finding.license] or 0) + 1
    end
    local names = vim.tbl_keys(tally)
    table.sort(names)
    vim.list_extend(
      lines,
      { '', '## Allowed', '', '| License | Count |', '| --- | ---: |' }
    )
    for _, name in ipairs(names) do
      table.insert(lines, ('| %s | %d |'):format(name, tally[name]))
    end
  end
  return lines,
    { deny = #groups.deny, warn = #groups.warn, allow = #groups.allow }
end

--- Check the packages of `sbom` and show the result
---@param sbom table A decoded SBOM
---@param root string
---@param source string What the SBOM came from, for the report
function M.show(sbom, root, source)
  local packages, err = M.packages(sbom)
  if not packages then
    return notify(source .. ' is ' .. err, vim.log.levels.ERROR)
  end
  if #packages == 0 then
    return notify(
      source .. ' lists no package: no license was checked',
      vim.log.levels.WARN
    )
  end
  local project, project_err = M.project_rules(root)
  if project_err then
    notify(project_err .. '; the default policy applies', vim.log.levels.ERROR)
  end
  local findings = M.check(packages, project)
  local header = {
    'Read from ' .. source .. '.',
    project and ('Policy: the defaults, with %s.'):format(M.FILE)
      or project_err and ('Policy: the defaults; %s.'):format(project_err)
      or 'Policy: the defaults.',
  }
  local lines, counts = M.report(findings, header)

  local items, cache = {}, {}
  for _, finding in ipairs(findings) do
    if finding.verdict ~= 'allow' then
      local where = M.locate(root, finding.item, cache)
      table.insert(items, {
        filename = where and where.filename,
        lnum = where and where.lnum or 0,
        type = finding.verdict == 'deny' and 'E' or 'W',
        text = ('%s %s: %s (%s)'):format(
          finding.item.name,
          finding.item.version,
          finding.license,
          finding.item.purl
        ),
      })
    end
  end
  local summary = ('%d denied, %d to review, %d allowed of %d'):format(
    counts.deny,
    counts.warn,
    counts.allow,
    #findings
  )
  vim.fn.setqflist({}, ' ', { title = 'Licenses: ' .. summary, items = items })
  require('util.scratch').open(lines, { filetype = 'markdown' })
  notify(
    counts.deny + counts.warn == 0
        and ('All %d licenses allowed'):format(#findings)
      or summary,
    counts.deny > 0 and vim.log.levels.ERROR
      or counts.warn > 0 and vim.log.levels.WARN
      or nil
  )
end

--- Read the SBOM at `path`, CycloneDX or SPDX JSON
---@param path string
---@param root string
function M.from_file(path, root)
  local stat = vim.uv.fs_stat(path)
  if not stat then return notify('No file ' .. path, vim.log.levels.ERROR) end
  if stat.size > M.MAX_SBOM then
    return notify(path .. ' is too large to read', vim.log.levels.ERROR)
  end
  local ok, sbom = pcall(
    vim.json.decode,
    table.concat(vim.fn.readfile(path), '\n'),
    { luanil = { object = true, array = true } }
  )
  if not ok or type(sbom) ~= 'table' then
    return notify(path .. ' is not JSON', vim.log.levels.ERROR)
  end
  M.show(sbom, root, vim.fn.fnamemodify(path, ':~'))
end

--- Have trivy list the packages of the project at `root`, then check them
---@param root string
function M.scan(root)
  local system = require('util.system')
  notify('Listing the packages of the project…')
  system.run(
    { 'trivy', 'fs', '--quiet', '--format', 'cyclonedx', root },
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_SBOM },
    function(result)
      if result.missing then
        require('util.lazy_install').install_once('trivy')
        return notify(
          'Installing trivy with Mason; run again once it is done',
          vim.log.levels.WARN
        )
      end
      if result.code ~= 0 or result.timed_out or result.cut then
        return notify(
          'trivy could not list the packages: '
            .. (
              result.cut and 'an SBOM larger than can be read'
              or system.failure(result, 'trivy')
            ),
          vim.log.levels.ERROR
        )
      end
      local ok, sbom = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(sbom) ~= 'table' then
        return notify('trivy wrote no SBOM', vim.log.levels.ERROR)
      end
      M.show(sbom, root, 'trivy fs')
    end
  )
end

--- `:DyLicenses [{sbom}]`: the project's packages from trivy, or from a
--- CycloneDX or SPDX JSON file
---@param args { fargs: string[] }
function M.command(args)
  local root = require('util.root')()
  local file = args.fargs[1]
  if file then
    return M.from_file(vim.fn.fnamemodify(vim.fn.expand(file), ':p'), root)
  end
  M.scan(root)
end

return M
