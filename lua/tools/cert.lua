--- What a certificate file holds, and whether its chain holds together
---
--- `:DyInspect` reads the one PEM block under the cursor; a certificate file
--- is often more than that: a chain of PEM blocks, a binary DER `.cer` or
--- its bare base64 with no PEM header, a PKCS#7 `.p7b` bundle. `:DyCert [file]` reads every certificate of the
--- file, or of the buffer (base64 in a Kubernetes Secret too), into a
--- scratch tab: a summary of the chain -- each certificate's subject, end
--- date and state, whether each is issued by the next, and what
--- `openssl verify` says against the system trust store -- then what each
--- certificate says, through `tools.inspect`.
---
--- A binary DER or PKCS#7 file opens as that report rather than its bytes,
--- in a buffer that is never written back. A PEM file stays text to edit. A
--- PKCS#12 bundle is not opened: it is password protected and holds a
--- private key.
local M = {}

--- The most of a file read, in bytes: a certificate file is a few KiB
M.LIMIT = 1024 * 1024

--- The most certificates of a file reported
M.MAX_CERTS = 20

--- Milliseconds each `openssl` run may take
M.TIMEOUT = 5000

--- Output kept of each `openssl` run
M.MAX_BYTES = 1024 * 1024

local notify = require('util.notify').titled('Cert')

--- What each form is called in the report
local FORMS = {
  pem = 'PEM',
  der = 'DER',
  pkcs7 = 'PKCS#7',
}

---@alias DyCertKind 'pem'|'der'|'pkcs7'|'pkcs12'

--- The form of a certificate file, from its name and bytes; nil when it is
--- none
---@param path string
---@param bytes string
---@return DyCertKind?
function M.kind(path, bytes)
  local ext = (path:match('%.(%w+)$') or ''):lower()
  if ext == 'p12' or ext == 'pfx' then return 'pkcs12' end
  if bytes:find('-----BEGIN ', 1, true) then return 'pem' end
  -- `LS0tLS1CRUdJTi` is the base64 of `-----BEGIN`
  if bytes:find('LS0tLS1CRUdJTi', 1, true) then return 'pem' end
  -- Every DER structure here is a SEQUENCE
  if bytes:byte(1) == 0x30 then
    return (ext == 'p7b' or ext == 'p7c') and 'pkcs7' or 'der'
  end
  return nil
end

--- The DER inside `bytes` when they are bare base64 of it, with no PEM
--- header -- the `.cer` Azure and Windows export -- or else `bytes` as they
--- are
---@param bytes string
---@return string
function M.unwrap(bytes)
  local text = bytes:gsub('%s', '')
  if text == '' or text:find('[^%w%+/=]') then return bytes end
  local decoded = require('tools.inspect').base64(text)
  -- Every DER structure here is a SEQUENCE
  if decoded and decoded:byte(1) == 0x30 then return decoded end
  return bytes
end

--- The bytes of `path`, or why they are not read
---@param path string
---@return string? bytes
---@return string? err
function M.read_file(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil, ('%s is not a file'):format(path)
  end
  if stat.size > M.LIMIT then
    return nil,
      ('%s is larger than %d KiB: no certificate file'):format(
        vim.fs.basename(path),
        M.LIMIT / 1024
      )
  end
  local file = io.open(path, 'rb')
  if not file then return nil, ('%s cannot be read'):format(path) end
  local bytes = file:read('*a') or ''
  file:close()
  return bytes
end

--- Run `openssl` with `input` on its stdin, and hand `on_done` its output or
--- why there is none
---@param args string[]
---@param input string
---@param on_done fun(stdout: string?, err: string?)
local function openssl(args, input, on_done)
  local system = require('util.system')
  system.run(
    vim.list_extend({ 'openssl' }, args),
    { stdin = input, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      if result.code ~= 0 or result.cut or result.timed_out then
        return on_done(nil, system.failure(result, 'openssl'))
      end
      on_done(result.stdout or '')
    end
  )
end

--- The PEM certificates in `text`
---@param text string
---@return string[]
local function pem_certificates(text)
  local found = require('tools.inspect').pems(vim.split(text, '\n'))
  return vim.tbl_map(
    function(block) return block.text end,
    vim.tbl_filter(
      function(block) return block.label == 'CERTIFICATE' end,
      found
    )
  )
end

--- Hand `on_done` the certificates of PEM `lines`, those of a PKCS#7 block
--- among them read through openssl
---@param lines string[]
---@param on_done fun(pems: string[], err: string?)
local function from_lines(lines, on_done)
  local blocks = require('tools.inspect').pems(lines)
  local pems, index, err = {}, 0, nil
  local function next_block()
    index = index + 1
    local block = blocks[index]
    if not block then return on_done(pems, err) end
    if block.label == 'CERTIFICATE' then
      table.insert(pems, block.text)
      return next_block()
    end
    if block.label ~= 'PKCS7' then return next_block() end
    openssl({ 'pkcs7', '-print_certs' }, block.text, function(out, why)
      if out then
        vim.list_extend(pems, pem_certificates(out))
      else
        err = why
      end
      next_block()
    end)
  end
  next_block()
end

---@class DyCertSource
---@field path? string A file to read
---@field lines? string[] The text of a buffer, read instead of a file
---@field name? string What the report is titled

--- Hand `on_done` the certificates of `source` as PEM, and the form they
--- came in; or why there are none
---@param source DyCertSource
---@param on_done fun(pems: string[]?, form: string?, err: string?)
function M.certificates(source, on_done)
  if source.lines then
    return from_lines(
      source.lines,
      function(pems, err) on_done(pems, FORMS.pem, err) end
    )
  end
  local bytes, err = M.read_file(assert(source.path))
  if not bytes then return on_done(nil, nil, err) end
  bytes = M.unwrap(bytes)
  local kind = M.kind(source.path, bytes)
  if not kind then return on_done(nil, nil, 'No certificate in this file') end
  if kind == 'pkcs12' then
    return on_done(
      nil,
      nil,
      'A PKCS#12 bundle is password protected and holds a private key: '
        .. 'it is not opened here (`openssl pkcs12 -info -nokeys -in <file>`)'
    )
  end
  if kind == 'pem' then
    return from_lines(
      vim.split(bytes, '\r?\n'),
      function(pems, why) on_done(pems, FORMS.pem, why) end
    )
  end
  local function pkcs7()
    openssl(
      { 'pkcs7', '-inform', 'DER', '-print_certs' },
      bytes,
      function(out, why)
        if not out then return on_done(nil, nil, why) end
        on_done(pem_certificates(out), FORMS.pkcs7)
      end
    )
  end
  if kind == 'pkcs7' then return pkcs7() end
  openssl(
    { 'x509', '-inform', 'DER', '-outform', 'PEM' },
    bytes,
    function(out, why)
      if out then return on_done(pem_certificates(out), FORMS.der) end
      -- A `.cer` is now and then a PKCS#7 bundle; nothing else to try when
      -- openssl is not there at all
      if why and why:find('not installed', 1, true) then
        return on_done(nil, nil, why)
      end
      pkcs7()
    end
  )
end

--- The subject and issuer in what `openssl x509 -subject -issuer` printed
---@param lines string[]
---@return { subject: string?, issuer: string? }
function M.fields(lines)
  local fields = {}
  for _, line in ipairs(lines) do
    for _, key in ipairs({ 'subject', 'issuer' }) do
      local value = line:match('^' .. key .. '=%s*(.-)%s*$')
      if value and not fields[key] then fields[key] = value end
    end
  end
  return fields
end

--- Where a chain, leaf first, is out of order: each certificate is to be
--- issued by the next
---@param certs { subject: string?, issuer: string? }[]
---@return string[]
function M.links(certs)
  local problems = {}
  for i = 1, #certs - 1 do
    if certs[i].issuer ~= certs[i + 1].subject then
      table.insert(
        problems,
        ('Certificate %d is not issued by certificate %d: its issuer is `%s`'):format(
          i,
          i + 1,
          certs[i].issuer or '?'
        )
      )
    end
  end
  return problems
end

--- The reason `openssl verify` gave, in a line
---@param err string
---@return string
local function verify_reason(err)
  local depth, reason = err:match('error %d+ at (%d+) depth lookup: ([^\n]+)')
  if reason then
    return ('%s (certificate %d)'):format(reason, tonumber(depth) + 1)
  end
  return vim.split(vim.trim(err), '\n')[1] or err
end

--- Hand `on_done` what `openssl verify` says of the leaf, the rest of the
--- chain given as untrusted intermediates
---@param pems string[]
---@param on_done fun(line: string)
local function verify(pems, on_done)
  local args = { 'verify' }
  local rest
  if #pems > 1 then
    -- Public certificates, removed once read
    rest = vim.fn.tempname()
    vim.fn.writefile(
      vim.split(table.concat(vim.list_slice(pems, 2), '\n'), '\n'),
      rest
    )
    vim.list_extend(args, { '-untrusted', rest })
  end
  openssl(args, pems[1], function(out, err)
    if rest then os.remove(rest) end
    if out then return on_done('OK against the system trust store') end
    on_done('**fails**: ' .. verify_reason(err or ''))
  end)
end

--- What a state says in the summary
local STATES = {
  ok = 'valid',
  soon = '**ends within %d days**',
  expired = '**expired**',
}

--- Hand `on_done` the report on `pems`, read from `name` in `form`
---@param name string
---@param form string
---@param pems string[]
---@param on_done fun(lines: string[])
function M.report(name, form, pems, on_done)
  local inspect = require('tools.inspect')
  local total = #pems
  pems = vim.list_slice(pems, 1, M.MAX_CERTS)
  local details, certs, states = {}, {}, {}
  local index = 0
  local function finish()
    local lines = {
      '# ' .. name,
      '',
      ('%d certificate%s, %s'):format(total, total == 1 and '' or 's', form),
    }
    if total > #pems then
      lines[3] = ('%s; the first %d are shown'):format(lines[3], #pems)
    end
    vim.list_extend(lines, { '', '## Chain', '' })
    for i, fields in ipairs(certs) do
      local state = states[i]
      local said = state.state and STATES[state.state]:format(inspect.WARN_DAYS)
        or 'not checked'
      local self = fields.subject
          and fields.subject == fields.issuer
          and ', self-signed'
        or ''
      table.insert(
        lines,
        ('%d. `%s` -- ends %s, %s%s'):format(
          i,
          fields.subject or '?',
          state.ends or '?',
          said,
          self
        )
      )
    end
    table.insert(lines, '')
    local problems = M.links(certs)
    if #problems == 0 then
      table.insert(
        lines,
        #certs > 1 and '- Order: each certificate is issued by the next'
          or '- Order: a single certificate'
      )
    else
      for _, problem in ipairs(problems) do
        table.insert(lines, '- Order: ' .. problem)
      end
    end
    verify(pems, function(trust)
      table.insert(lines, '- Trust: ' .. trust)
      for i, detail in ipairs(details) do
        vim.list_extend(
          lines,
          { '', ('## Certificate %d of %d'):format(i, #pems), '' }
        )
        vim.list_extend(lines, detail)
      end
      on_done(lines)
    end)
  end
  local function next_cert()
    index = index + 1
    local pem = pems[index]
    if not pem then return finish() end
    inspect.pem(
      { kind = 'pem', label = 'CERTIFICATE', text = pem, first = 1, last = 1 },
      function(lines, err)
        -- `tools.inspect` titles it `# CERTIFICATE`: the report has its own
        local detail = lines and vim.list_slice(lines, 3)
          or { 'Could not read it: ' .. (err or '?') }
        details[index] = detail
        certs[index] = M.fields(detail)
        inspect.expiry(pem, function(state, ends)
          states[index] = { state = state, ends = ends }
          next_cert()
        end)
      end
    )
  end
  next_cert()
end

--- Hand `on_done` the lines that show `source`: the report, or why there is
--- none
---@param source DyCertSource
---@param on_done fun(lines: string[])
function M.build(source, on_done)
  local name = source.name
    or (source.path and vim.fs.basename(source.path))
    or 'Certificates'
  M.certificates(source, function(pems, form, err)
    if not pems or #pems == 0 then
      return on_done({
        '# ' .. name,
        '',
        err or 'No certificate in this file',
      })
    end
    M.report(name, assert(form), pems, function(lines)
      if err then vim.list_extend(lines, { '', 'Not all read: ' .. err }) end
      on_done(lines)
    end)
  end)
end

--- Show the report on a binary certificate file in its own buffer, just
--- read through `BufReadPost`, in place of its bytes; a PEM file is left as
--- the text it is
---@param bufnr integer
function M.read(bufnr)
  local name = vim.api.nvim_buf_get_name(bufnr)
  -- `fugitive://`, `scp://`, `oil://`: a buffer another plugin reads
  if name:match('^%a[%w+.-]*://') then return end
  local path = vim.fs.normalize(vim.fn.fnamemodify(name, ':p'))
  local bytes = M.read_file(path)
  local kind = bytes and M.kind(path, M.unwrap(bytes))
  if kind ~= 'der' and kind ~= 'pkcs7' then return end
  -- The report is no copy of the file: it must never be written over it
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].undolevels = -1
  local scratch = require('util.scratch')
  scratch.set(bufnr, { 'Reading ' .. vim.fs.basename(path) .. ' ...' })
  vim.bo[bufnr].modifiable = false
  vim.bo[bufnr].filetype = 'markdown'
  M.build({ path = path }, function(lines) scratch.set(bufnr, lines) end)
end

--- `:DyCert [file]`: the certificates of `file`, or else of the buffer
---@param args { fargs: string[] }
function M.command(args)
  local source
  if args.fargs[1] then
    source =
      { path = vim.fs.normalize(vim.fn.fnamemodify(args.fargs[1], ':p')) }
  else
    local bufnr = vim.api.nvim_get_current_buf()
    local name = vim.api.nvim_buf_get_name(bufnr)
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    -- The buffer's text first: it holds the edits not yet written, and a
    -- binary file's buffer holds its report
    if
      vim.bo[bufnr].buftype == ''
      and #require('tools.inspect').pems(lines) > 0
    then
      source = {
        lines = lines,
        name = name ~= '' and vim.fs.basename(name) or nil,
      }
    elseif name ~= '' and not name:match('^%a[%w+.-]*://') then
      source = { path = name }
    else
      return notify('No certificate in this buffer', vim.log.levels.WARN)
    end
  end
  M.build(
    source,
    function(lines)
      require('util.scratch').open(lines, {
        filetype = 'markdown',
        sensitive = 'decoded from a certificate file',
      })
    end
  )
end

return M
