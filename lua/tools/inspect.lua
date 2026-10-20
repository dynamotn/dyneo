--- What a certificate, a key or a token under the cursor says
---
--- Infrastructure files carry them inline: a PEM block in a config, the
--- base64 of one in a Kubernetes Secret (`tls.crt: LS0tLS1CRUdJTi...`), a
--- JWT pasted from a request. `:DyInspect` decodes the one under the cursor
--- into a scratch buffer held back from every AI integration: a certificate
--- through `openssl x509` (subject, issuer, names, validity, fingerprint), a
--- JWT in Lua (header and claims, its times as dates; the signature is
--- never shown). A private key is named, never decoded.
---
--- `:DyInspect expiry` checks every certificate of the buffer, and warns on
--- the line of each one expired or expiring within `M.WARN_DAYS`.
local M = {}

local scratch = require('util.scratch')

local ns = vim.api.nvim_create_namespace('dy_inspect')

--- Days before its end a certificate is warned about
M.WARN_DAYS = 30

--- Milliseconds `openssl` may take
M.TIMEOUT = 5000

local notify = require('util.notify').titled('Inspect')

--- base64 or base64url text decoded, or nil when it is not
---@param text string
---@return string?
function M.base64(text)
  text = text:gsub('%s', ''):gsub('-', '+'):gsub('_', '/')
  local pad = #text % 4
  if pad == 1 then return nil end
  if pad > 0 then text = text .. ('='):rep(4 - pad) end
  local ok, decoded = pcall(vim.base64.decode, text)
  return ok and decoded or nil
end

---@class DyInspectFound
---@field kind 'pem'|'jwt'
---@field text string The PEM block, or the token
---@field first integer 1-based line where it starts
---@field last integer
---@field label? string The label of a PEM block: `CERTIFICATE`, ...

--- The PEM blocks of `lines`, plain or base64 encoded on one line as in a
--- Kubernetes Secret
---@param lines string[]
---@return DyInspectFound[]
function M.pems(lines)
  local found, open = {}, nil
  for number, line in ipairs(lines) do
    local begin = line:match('%-%-%-%-%-BEGIN ([%u ]+)%-%-%-%-%-')
    if begin then
      open = { kind = 'pem', label = begin, first = number, body = {} }
    end
    if open then
      table.insert(open.body, vim.trim(line))
      if line:match('%-%-%-%-%-END [%u ]+%-%-%-%-%-') then
        local text = table.concat(open.body, '\n')
        -- From BEGIN to END only: the key before it on the line goes
        text = text:match('(%-%-%-%-%-BEGIN.*%-%-%-%-%-END [%u ]+%-%-%-%-%-)')
        if text then
          table.insert(found, {
            kind = 'pem',
            label = open.label,
            text = text,
            first = open.first,
            last = number,
          })
        end
        open = nil
      end
    else
      -- `LS0tLS1CRUdJTi` is the base64 of `-----BEGIN`
      for blob in line:gmatch('(LS0tLS1CRUdJTi[%w%+/=]+)') do
        local decoded = M.base64(blob)
        -- A bundle -- the leaf and its chain, as cert-manager writes
        -- `tls.crt` -- is each of its blocks, all on this line
        for _, block in
          ipairs(decoded and M.pems(vim.split(decoded, '\r?\n')) or {})
        do
          block.first, block.last = number, number
          table.insert(found, block)
        end
      end
    end
  end
  return found
end

--- The JWT in `line` around byte `col` (1-based), or the first one in it
---@param line string
---@param col? integer
---@return string?
function M.jwt_at(line, col)
  local first
  for s, token, e in line:gmatch('()(eyJ[%w_%-]+%.eyJ[%w_%-]+%.[%w_%-]*)()') do
    first = first or token
    if col and col >= s and col < e then return token end
  end
  return first
end

--- When a NumericDate claim falls, in UTC
---@param value any
---@return string?
local function date(value)
  local number = tonumber(value)
  if not number then return nil end
  return os.date('!%Y-%m-%d %H:%M:%S UTC', number) --[[@as string]]
end

--- The header and claims of a JWT, for reading; never its signature
---@param token string
---@param now? integer Seconds since the epoch
---@return string[]? lines
---@return string? err
function M.jwt(token, now)
  local header, payload = token:match('^([%w_%-]+)%.([%w_%-]+)%.')
  if not header then return nil, 'Not a JWT' end
  local parts = {}
  for _, part in ipairs({ header, payload }) do
    local json = M.base64(part)
    local ok, decoded = pcall(
      vim.json.decode,
      json or '',
      { luanil = { object = true, array = true } }
    )
    if not ok or type(decoded) ~= 'table' then
      return nil, 'Not a JWT: a part is not base64 JSON'
    end
    table.insert(parts, decoded)
  end
  now = now or os.time()
  local claims = parts[2]
  local lines = { '# JWT', '', '## Header', '' }
  local function pretty(value)
    local ok, json =
      pcall(vim.json.encode, value, { indent = '  ', sort_keys = true })
    return vim.split(ok and json or vim.json.encode(value), '\n')
  end
  vim.list_extend(lines, pretty(parts[1]))
  vim.list_extend(lines, { '', '## Claims', '' })
  vim.list_extend(lines, pretty(claims))
  local times = {}
  for _, key in ipairs({ 'iat', 'nbf', 'exp' }) do
    if date(claims[key]) then
      table.insert(times, ('- %s: %s'):format(key, date(claims[key])))
    end
  end
  if #times > 0 then
    vim.list_extend(lines, { '', '## Times', '' })
    vim.list_extend(lines, times)
    local exp = tonumber(claims.exp)
    if exp then
      table.insert(
        lines,
        exp < now and '- **expired**'
          or ('- valid for %d more minutes'):format(
            math.floor((exp - now) / 60)
          )
      )
    end
  end
  vim.list_extend(lines, { '', 'The signature is not shown, nor checked.' })
  return lines
end

--- Run `openssl` with `pem` on its input, off the main loop, never raising
---@param args string[]
---@param pem string
---@param on_done fun(result: vim.SystemCompleted?) Nil when it cannot run
local function openssl(args, pem, on_done)
  require('util.system').run(
    vim.list_extend({ 'openssl' }, args),
    { stdin = pem, timeout = M.TIMEOUT },
    function(result) on_done(not result.missing and result or nil) end
  )
end

--- The `openssl` arguments that print what a block of `label` says
local READERS = {
  -- The extensions through `-text` with all else left out, rather than
  -- `-ext`: the LibreSSL of macOS has no `-ext`
  CERTIFICATE = {
    'x509',
    '-noout',
    '-subject',
    '-issuer',
    '-dates',
    '-serial',
    '-fingerprint',
    '-sha256',
    '-text',
    '-certopt',
    'no_header,no_version,no_serial,no_signame,no_validity,no_subject,'
      .. 'no_issuer,no_pubkey,no_sigdump,no_aux',
  },
  ['CERTIFICATE REQUEST'] = { 'req', '-noout', '-subject', '-text' },
  ['PUBLIC KEY'] = { 'pkey', '-pubin', '-noout', '-text' },
}

--- Hand `on_done` what a PEM block says, for reading
---@param found DyInspectFound
---@param on_done fun(lines: string[]?, err: string?)
function M.pem(found, on_done)
  local label = found.label or ''
  if label:match('PRIVATE KEY') then
    return on_done({
      '# ' .. label,
      '',
      'A private key: it is not decoded or shown here.',
    })
  end
  local args = READERS[label]
  if not args then
    return on_done(nil, ('No reader for a %s block'):format(label))
  end
  openssl(args, found.text, function(result)
    if not result then return on_done(nil, 'openssl is not installed') end
    if result.code ~= 0 then
      return on_done(
        nil,
        'openssl could not read it: ' .. vim.trim(result.stderr or '')
      )
    end
    local lines = { '# ' .. label, '' }
    vim.list_extend(
      lines,
      vim.split(vim.trim(result.stdout or ''), '\n', { plain = true })
    )
    on_done(lines)
  end)
end

--- Show `lines`, or why there are none
---@param lines? string[]
---@param err? string
local function present(lines, err)
  if not lines then return notify(err, vim.log.levels.WARN) end
  scratch.open(lines, {
    split = 'horizontal',
    filetype = 'markdown',
    sensitive = 'decoded from a certificate, a key or a token',
  })
end

--- Show what the certificate, key or token under the cursor says
function M.under_cursor()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local token = M.jwt_at(lines[row] or '', col + 1)
  if token then return present(M.jwt(token)) end
  for _, found in ipairs(M.pems(lines)) do
    if row >= found.first and row <= found.last then
      return M.pem(found, present)
    end
  end
  present(nil, 'No certificate, key or JWT under the cursor')
end

--- What `openssl x509 -checkend` answered: whether the certificate ends
--- within the time asked, or nil when it did not answer -- not installed,
--- killed by the timeout, or failed with another exit
---@param result? vim.SystemCompleted
---@return boolean?
local function ends_within(result)
  if not result or result.signal ~= 0 then return nil end
  if result.code == 0 then return false end
  if result.code == 1 then return true end
  return nil
end

--- Hand `on_done` how long `pem` has left: 'expired', 'soon' or 'ok', and
--- its end date; nothing when openssl cannot read it or does not answer
---@param pem string
---@param on_done fun(state: 'expired'|'soon'|'ok'|nil, ends: string?)
function M.expiry(pem, on_done)
  openssl({ 'x509', '-noout', '-enddate' }, pem, function(ends)
    if not ends or ends.code ~= 0 then return on_done(nil) end
    local when = vim.trim((ends.stdout or ''):gsub('^notAfter=', ''))
    openssl({ 'x509', '-noout', '-checkend', '0' }, pem, function(now)
      local expired = ends_within(now)
      if expired == nil then return on_done(nil, when) end
      if expired then return on_done('expired', when) end
      openssl(
        { 'x509', '-noout', '-checkend', tostring(M.WARN_DAYS * 86400) },
        pem,
        function(soon)
          local ending = ends_within(soon)
          if ending == nil then return on_done(nil, when) end
          on_done(ending and 'soon' or 'ok', when)
        end
      )
    end)
  end)
end

--- Warn on the line of each certificate of the buffer expired or ending
--- soon, the certificates checked one after the other off the main loop
---@param bufnr? integer
function M.check_expiry(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  if vim.fn.executable('openssl') ~= 1 then
    return notify('openssl is not installed', vim.log.levels.ERROR)
  end
  local certificates = vim.tbl_filter(
    function(found) return found.label == 'CERTIFICATE' end,
    M.pems(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  )
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  local diagnostics, index, unchecked = {}, 0, 0
  local function next_certificate()
    index = index + 1
    local found = certificates[index]
    if not found then
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      -- Edited meanwhile: the lines found may point elsewhere now
      if vim.api.nvim_buf_get_changedtick(bufnr) ~= tick then
        return notify(
          'The buffer changed meanwhile: check again',
          vim.log.levels.WARN
        )
      end
      vim.diagnostic.set(ns, bufnr, diagnostics)
      local summary = ('%d certificates checked, %d expired or ending soon'):format(
        #certificates - unchecked,
        #diagnostics - unchecked
      )
      if unchecked > 0 then
        summary = ('%s, %d could not be checked'):format(summary, unchecked)
      end
      return notify(summary, #diagnostics > 0 and vim.log.levels.WARN or nil)
    end
    M.expiry(found.text, function(state, when)
      if not state then
        unchecked = unchecked + 1
        table.insert(diagnostics, {
          lnum = found.first - 1,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          message = 'Certificate could not be checked',
          source = 'inspect',
        })
      elseif state == 'expired' or state == 'soon' then
        table.insert(diagnostics, {
          lnum = found.first - 1,
          col = 0,
          severity = state == 'expired' and vim.diagnostic.severity.ERROR
            or vim.diagnostic.severity.WARN,
          message = state == 'expired'
              and ('Certificate expired on %s'):format(when)
            or ('Certificate expires on %s, within %d days'):format(
              when,
              M.WARN_DAYS
            ),
          source = 'inspect',
        })
      end
      next_certificate()
    end)
  end
  next_certificate()
end

--- `:DyInspect [expiry]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if not sub then return M.under_cursor() end
  if sub == 'expiry' then return M.check_expiry(0) end
  notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
end

return M
