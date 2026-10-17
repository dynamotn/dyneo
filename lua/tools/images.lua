--- The container images a file runs: what is known wrong with them, and
--- the digest to pin them to
---
--- A Dockerfile names its bases in `FROM`, a manifest or a compose file in
--- `image:`. `:DyImageScan` asks `trivy image` (or `grype`) about each one and
--- puts what it found on its line: how many vulnerabilities, by severity,
--- and the worst of their ids. `:DyImagePin` pins each tag to the digest it
--- points at now, `nginx:1.27@sha256:…`, through `crane` or `skopeo`, so a
--- tag pushed again does not change what runs.
local M = {}

--- The most a scan report may take; trivy's JSON of a large image is big
M.MAX_REPORT = 64 * 1024 * 1024

--- Digest lookups running at once
M.PARALLEL = 4

local ns = vim.api.nvim_create_namespace('dy_images')

--- Milliseconds a scan of one image may take: the first one downloads the
--- vulnerability database
M.TIMEOUT = 10 * 60 * 1000

local notify = require('util.notify').titled('Images')

---@class DyImageRef
---@field line integer 1-based
---@field image string As written: `nginx:1.27`, `ghcr.io/o/r@sha256:…`

--- The images `lines` name: `FROM` of a Dockerfile (stages and `scratch`
--- left out), `image:` of YAML. A name holding a variable, or starting with
--- `-`, is left out.
---@param lines string[]
---@return DyImageRef[]
function M.images(lines)
  local refs, stages = {}, {}
  for number, line in ipairs(lines) do
    local from = line:match('^%s*[Ff][Rr][Oo][Mm]%s+(.+)$')
    local image
    if from then
      -- Flags first: `--platform=$BUILDPLATFORM`
      while from:match('^%-%-%S+%s+') do
        from = from:gsub('^%-%-%S+%s+', '', 1)
      end
      local name, stage = from:match('^(%S+)%s+[Aa][Ss]%s+(%S+)')
      image = name or from:match('^(%S+)')
      if stage then stages[stage:lower()] = true end
      if image and (image == 'scratch' or stages[image:lower()]) then
        image = nil
      end
    else
      image = line:match('^%s*%-?%s*image:%s*["\']?([^%s"\'#]+)')
    end
    -- A variable or a Helm template is no image to ask a registry about, and
    -- a name starting with `-` would reach trivy, grype or crane as a flag
    if
      image
      and not image:find('%$')
      and not image:find('{{', 1, true)
      and not image:find('^%-')
    then
      table.insert(refs, { line = number, image = image })
    end
  end
  return refs
end

---@class DyImageFindings
---@field counts table<string, integer> By severity: CRITICAL, HIGH, ...
---@field ids string[] Worst first

local ORDER = { 'CRITICAL', 'HIGH', 'MEDIUM', 'LOW', 'UNKNOWN', 'NEGLIGIBLE' }
local RANK = {}
for index, name in ipairs(ORDER) do
  RANK[name] = index
end

--- The vulnerabilities of a `trivy image --format json` or `grype -o json`
--- report, counted by severity
---@param report table
---@return DyImageFindings
function M.findings(report)
  local found = {}
  -- trivy: Results[].Vulnerabilities[]
  for _, result in
    ipairs(type(report.Results) == 'table' and report.Results or {})
  do
    for _, vuln in
      ipairs(
        type(result.Vulnerabilities) == 'table' and result.Vulnerabilities or {}
      )
    do
      table.insert(
        found,
        { id = vuln.VulnerabilityID, severity = vuln.Severity }
      )
    end
  end
  -- grype: matches[].vulnerability
  for _, match in
    ipairs(type(report.matches) == 'table' and report.matches or {})
  do
    local vuln = type(match) == 'table' and match.vulnerability or {}
    table.insert(found, { id = vuln.id, severity = vuln.severity })
  end

  local counts, seen, ids = {}, {}, {}
  for _, vuln in ipairs(found) do
    local severity = type(vuln.severity) == 'string' and vuln.severity:upper()
      or 'UNKNOWN'
    if not RANK[severity] then severity = 'UNKNOWN' end
    counts[severity] = (counts[severity] or 0) + 1
    if type(vuln.id) == 'string' and not seen[vuln.id] then
      seen[vuln.id] = true
      table.insert(ids, { id = vuln.id, rank = RANK[severity] })
    end
  end
  table.sort(ids, function(a, b)
    if a.rank ~= b.rank then return a.rank < b.rank end
    return a.id < b.id
  end)
  return {
    counts = counts,
    ids = vim.tbl_map(function(item) return item.id end, ids),
  }
end

--- The diagnostic of the findings of one image
---@param ref DyImageRef
---@param findings DyImageFindings
---@return vim.Diagnostic?
function M.diagnostic(ref, findings)
  local parts = {}
  for _, severity in ipairs(ORDER) do
    if findings.counts[severity] then
      table.insert(parts, ('%s %d'):format(severity, findings.counts[severity]))
    end
  end
  if #parts == 0 then return nil end
  local severity = vim.diagnostic.severity.INFO
  if findings.counts.CRITICAL or findings.counts.HIGH then
    severity = vim.diagnostic.severity.ERROR
  elseif findings.counts.MEDIUM then
    severity = vim.diagnostic.severity.WARN
  end
  local ids = vim.list_slice(findings.ids, 1, 5)
  return {
    lnum = ref.line - 1,
    col = 0,
    severity = severity,
    message = ('%s: %s%s'):format(
      ref.image,
      table.concat(parts, ', '),
      #ids > 0
          and (' (' .. table.concat(ids, ', ') .. (#findings.ids > 5 and ', …' or '') .. ')')
        or ''
    ),
    source = 'image scan',
  }
end

--- The scanner to use, and its command for `image`
---@param image string
---@return string[]?
function M.scan_command(image)
  if vim.fn.executable('trivy') == 1 then
    return {
      'trivy',
      'image',
      '--quiet',
      '--format',
      'json',
      '--scanners',
      'vuln',
      image,
    }
  end
  if vim.fn.executable('grype') == 1 then
    return { 'grype', '--quiet', '-o', 'json', image }
  end
  return nil
end

--- Scan every image of the buffer, one after the other, and show what each
--- scan found on its line
---@param bufnr? integer
function M.scan(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local refs = M.images(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if #refs == 0 then return notify('No image named in this buffer') end
  if not M.scan_command('x') then
    return notify('Neither trivy nor grype is installed', vim.log.levels.ERROR)
  end
  -- One scan per image, however many lines name it
  local seen, order = {}, {}
  for _, ref in ipairs(refs) do
    if not seen[ref.image] then
      seen[ref.image] = true
      table.insert(order, ref.image)
    end
  end
  vim.diagnostic.reset(ns, bufnr)
  notify(('Scanning %d images…'):format(#order))
  ---@type table<string, DyImageFindings>
  local found, failed, vulnerable = {}, {}, 0
  local index = 0
  local function next_image()
    index = index + 1
    local image = order[index]
    if not image then
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      -- The scans take minutes: the findings go on the lines naming each
      -- image now, wherever an edit meanwhile moved them
      local diagnostics = {}
      for _, ref in
        ipairs(M.images(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)))
      do
        local diagnostic = found[ref.image]
          and M.diagnostic(ref, found[ref.image])
        if diagnostic then table.insert(diagnostics, diagnostic) end
      end
      vim.diagnostic.set(ns, bufnr, diagnostics)
      return notify(
        ('%d images scanned, %d with known vulnerabilities%s'):format(
          #order - #failed,
          vulnerable,
          #failed > 0 and ('; failed: ' .. table.concat(failed, ', ')) or ''
        ),
        (vulnerable > 0 or #failed > 0) and vim.log.levels.WARN or nil
      )
    end
    require('util.system').run(
      M.scan_command(image),
      { timeout = M.TIMEOUT, max_bytes = M.MAX_REPORT },
      function(result)
        local ok, report = pcall(
          vim.json.decode,
          result.stdout or '',
          { luanil = { object = true, array = true } }
        )
        -- A report cut short is no report: never read as fewer findings
        if
          result.code ~= 0
          or result.cut
          or not ok
          or type(report) ~= 'table'
        then
          table.insert(failed, image)
        else
          local findings = M.findings(report)
          if next(findings.counts) then vulnerable = vulnerable + 1 end
          found[image] = findings
        end
        next_image()
      end
    )
  end
  next_image()
end

--- `image` without its digest, and the digest, if any
---@param image string
---@return string name
---@return string? digest
function M.split_digest(image)
  local name, digest = image:match('^(.-)@(sha256:%x+)$')
  return name or image, digest
end

--- The command printing the digest `image` points at now
---@param image string
---@return string[]?
function M.digest_command(image)
  if vim.fn.executable('crane') == 1 then
    return { 'crane', 'digest', image }
  end
  if vim.fn.executable('skopeo') == 1 then
    return {
      'skopeo',
      'inspect',
      '--format',
      '{{.Digest}}',
      'docker://' .. image,
    }
  end
  return nil
end

--- Pin every image of the buffer to the digest its tag points at
---@param bufnr? integer
function M.pin(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local todo = vim.tbl_filter(
    function(ref) return select(2, M.split_digest(ref.image)) == nil end,
    M.images(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  )
  if #todo == 0 then return notify('Every image is pinned already') end
  if not M.digest_command('x') then
    return notify('Neither crane nor skopeo is installed', vim.log.levels.ERROR)
  end
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local digests, failed = {}, {}
  local asked, seen = {}, {}
  for _, ref in ipairs(todo) do
    if not seen[ref.image] then
      seen[ref.image] = true
      table.insert(asked, ref.image)
    end
  end
  local function finish()
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
      return notify(
        'The file changed meanwhile: nothing pinned',
        vim.log.levels.WARN
      )
    end
    local count = 0
    for _, ref in ipairs(todo) do
      local digest = digests[ref.image]
      if digest then
        local line =
          vim.api.nvim_buf_get_lines(bufnr, ref.line - 1, ref.line, false)[1]
        local s, e = line:find(ref.image, 1, true)
        if s then
          vim.api.nvim_buf_set_lines(bufnr, ref.line - 1, ref.line, false, {
            line:sub(1, e) .. '@' .. digest .. line:sub(e + 1),
          })
          count = count + 1
        end
      end
    end
    table.sort(failed)
    notify(
      ('%d images pinned'):format(count)
        .. (
          #failed > 0 and ('; not resolved: ' .. table.concat(failed, ', '))
          or ''
        ),
      #failed > 0 and vim.log.levels.WARN or nil
    )
  end
  -- A few at a time: one request per image, all to the same registries
  require('util.system').each(asked, M.PARALLEL, function(image, done)
    require('util.system').run(
      M.digest_command(image),
      { timeout = 60000 },
      function(result)
        local digest = vim.trim(result.stdout or ''):match('^(sha256:%x+)$')
        if result.code == 0 and digest then
          digests[image] = digest
        else
          table.insert(failed, image)
        end
        done()
      end
    )
  end, finish)
end

return M
