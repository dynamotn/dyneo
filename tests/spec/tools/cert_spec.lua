local h = require('helpers')

--- Run `openssl` with `args`, failing the spec when it does not succeed
---@param args string[]
---@param dir string
local function openssl(args, dir)
  local result = require('util.system').sync(
    vim.list_extend({ 'openssl' }, args),
    { text = true, cwd = dir, timeout = 10000 }
  )
  assert.equals(0, result.code, result.stderr)
end

--- A self-signed CA, a leaf it signed, and the files a chain comes in
---@param dir string
local function make_chain(dir)
  local ec = { '-newkey', 'ec', '-pkeyopt', 'ec_paramgen_curve:prime256v1' }
  -- The keys go to files of their own, never into the spec's text
  openssl(
    vim.list_extend(vim.list_extend({ 'req', '-x509' }, ec), {
      '-nodes',
      '-days',
      '1',
      '-subj',
      '/CN=ca.test',
      '-keyout',
      'ca.key',
      '-out',
      'ca.pem',
    }),
    dir
  )
  openssl(
    vim.list_extend(vim.list_extend({ 'req' }, ec), {
      '-nodes',
      '-subj',
      '/CN=leaf.test',
      '-keyout',
      'leaf.key',
      '-out',
      'leaf.csr',
    }),
    dir
  )
  openssl({
    'x509',
    '-req',
    '-in',
    'leaf.csr',
    '-CA',
    'ca.pem',
    '-CAkey',
    'ca.key',
    '-CAcreateserial',
    '-days',
    '1',
    '-out',
    'leaf.pem',
  }, dir)
  openssl(
    { 'x509', '-in', 'leaf.pem', '-outform', 'DER', '-out', 'leaf.der' },
    dir
  )
  vim.fn.writefile(
    vim.list_extend(
      vim.fn.readfile(dir .. '/leaf.pem'),
      vim.fn.readfile(dir .. '/ca.pem')
    ),
    dir .. '/chain.pem'
  )
  openssl({
    'crl2pkcs7',
    '-nocrl',
    '-certfile',
    'chain.pem',
    '-outform',
    'DER',
    '-out',
    'chain.p7b',
  }, dir)
end

--- The lines `build` hands back for `source`, waited for
---@param cert table The module
---@param source table
---@return string text
local function built(cert, source)
  local lines
  cert.build(source, function(out) lines = out end)
  assert.is_true(vim.wait(10000, function() return lines ~= nil end, 10))
  return table.concat(lines, '\n')
end

describe('tools.cert', function()
  local cert, dir, cleanup, path

  before_each(function()
    path = vim.env.PATH
    h.unload('tools.cert', 'tools.inspect', 'util.scratch')
    cert = require('tools.cert')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.env.PATH = path
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('tells the form of a certificate file from its bytes', function()
    assert.equals('pem', cert.kind('a.crt', '-----BEGIN CERTIFICATE-----\n'))
    assert.equals('pem', cert.kind('s.yaml', 'tls.crt: LS0tLS1CRUdJTiBD'))
    assert.equals('der', cert.kind('a.cer', '\48\3abc'))
    assert.equals('pkcs7', cert.kind('a.P7B', '\48\3abc'))
    -- A SEQUENCE whose length is not the file's is no DER file
    assert.is_nil(cert.kind('a.cer', '\48\130\1\10'))
    assert.is_nil(cert.kind('a.cer', '0 fingerprint'))
    assert.equals('pkcs12', cert.kind('a.pfx', '\48\130\1\10'))
    assert.is_nil(cert.kind('a.crt', 'hello'))
  end)

  it('unwraps DER written as bare base64, and nothing else', function()
    local der = '\48\3abc'
    local text = vim.base64.encode(der)
    assert.equals(der, cert.unwrap(text))
    -- Wrapped at 64 columns with CRLF, as Windows exports it
    assert.equals(der, cert.unwrap(text:sub(1, 4) .. '\r\n' .. text:sub(5)))
    assert.equals('der', cert.kind('a.cer', cert.unwrap(text)))
    -- Base64 that is no DER, or text that is no base64, stays as it is
    local other = vim.base64.encode('hello there')
    assert.equals(other, cert.unwrap(other))
    assert.equals('not base64!', cert.unwrap('not base64!'))
    assert.equals(der, cert.unwrap(der))
  end)

  it('reads subject and issuer from what openssl prints', function()
    assert.same(
      { subject = 'CN = a', issuer = 'CN = b' },
      cert.fields({ 'subject=CN = a', 'issuer=CN = b', 'notAfter=x' })
    )
    -- LibreSSL puts a space and a slash form
    assert.same(
      { subject = '/CN=a', issuer = '/CN=a' },
      cert.fields({ 'subject= /CN=a', 'issuer= /CN=a' })
    )
  end)

  it('says where a chain is out of order', function()
    assert.same({}, cert.links({}))
    assert.same(
      {},
      cert.links({
        { subject = 'leaf', issuer = 'ca' },
        { subject = 'ca', issuer = 'ca' },
      })
    )
    assert.same(
      { 'Certificate 1 is not issued by certificate 2: its issuer is `ca`' },
      cert.links({
        { subject = 'leaf', issuer = 'ca' },
        { subject = 'other', issuer = 'ca' },
      })
    )
    -- Two certificates openssl could not read are no chain in order
    assert.same({
      'Certificate 1 could not be read: its subject or issuer is missing',
      'Certificate 2 could not be read: its subject or issuer is missing',
    }, cert.links({ {}, {} }))
    assert.same(
      { 'Certificate 2 could not be read: its subject or issuer is missing' },
      cert.links({ { subject = 'leaf', issuer = 'ca' }, { issuer = 'ca' } })
    )
  end)

  it('refuses a PKCS#12 bundle without running openssl', function()
    h.write(dir .. '/bundle.p12', { 'x' })
    vim.fn.mkdir(dir .. '/empty', 'p')
    vim.env.PATH = dir .. '/empty'
    local text = built(cert, { path = dir .. '/bundle.p12' })
    assert.is_truthy(text:find('PKCS#12', 1, true))
    assert.is_falsy(text:find('not installed', 1, true))
  end)

  it('says when openssl is not installed', function()
    vim.fn.writefile({ '\48\3abc' }, dir .. '/a.der', 'b')
    vim.fn.mkdir(dir .. '/empty', 'p')
    vim.env.PATH = dir .. '/empty'
    local text = built(cert, { path = dir .. '/a.der' })
    assert.is_truthy(text:find('openssl is not installed', 1, true))
  end)

  it('says what is not a certificate file', function()
    h.write(dir .. '/notes.txt', { 'hello' })
    local text = built(cert, { path = dir .. '/notes.txt' })
    assert.is_truthy(text:find('No certificate', 1, true))
  end)

  describe('with openssl', function()
    local ready
    before_each(function()
      ready = false
      if vim.fn.executable('openssl') ~= 1 then
        -- On every CI runner: missing there, these cases would test nothing
        assert(not vim.env.CI, 'no openssl on CI')
        return
      end
      make_chain(dir)
      ready = true
    end)

    it('shows every certificate of a PEM chain, in order', function()
      if not ready then return pending('openssl is not installed') end
      local text = built(cert, { path = dir .. '/chain.pem' })
      assert.is_truthy(text:find('2 certificates', 1, true))
      assert.is_truthy(text:find('## Certificate 1 of 2', 1, true))
      assert.is_truthy(text:find('## Certificate 2 of 2', 1, true))
      assert.is_truthy(text:find('CN%s*=%s*leaf.test'))
      assert.is_truthy(
        text:find('each certificate is issued by the next', 1, true)
      )
      assert.is_truthy(text:find('self-signed', 1, true))
      assert.is_truthy(text:find('- Trust: ', 1, true))
    end)

    it('reads a DER certificate and a PKCS#7 bundle', function()
      if not ready then return pending('openssl is not installed') end
      local der = built(cert, { path = dir .. '/leaf.der' })
      assert.is_truthy(der:find('1 certificate, DER', 1, true))
      assert.is_truthy(der:find('CN%s*=%s*leaf.test'))
      local p7b = built(cert, { path = dir .. '/chain.p7b' })
      assert.is_truthy(p7b:find('2 certificates, PKCS#7', 1, true))
      assert.is_truthy(p7b:find('CN%s*=%s*ca.test'))
    end)

    it('reads the certificates of a buffer, base64 in a Secret too', function()
      if not ready then return pending('openssl is not installed') end
      local pem = table.concat(vim.fn.readfile(dir .. '/leaf.pem'), '\n')
      local bufnr = h.buffer({
        lines = { 'data:', '  tls.crt: ' .. vim.base64.encode(pem) },
      })
      vim.api.nvim_set_current_buf(bufnr)
      cert.command({ fargs = {} })
      assert.is_true(
        vim.wait(
          10000,
          function() return vim.api.nvim_get_current_buf() ~= bufnr end,
          10
        )
      )
      local out = vim.api.nvim_get_current_buf()
      local text =
        table.concat(vim.api.nvim_buf_get_lines(out, 0, -1, false), '\n')
      assert.is_truthy(text:find('CN%s*=%s*leaf.test'))
      assert.is_false(vim.bo[out].modifiable)
    end)

    it('opens a DER file as what it says, never to be written', function()
      if not ready then return pending('openssl is not installed') end
      vim.cmd.source(h.root .. '/plugin/cert.lua')
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/leaf.der'))
      local bufnr = vim.api.nvim_get_current_buf()
      assert.equals('nofile', vim.bo[bufnr].buftype)
      assert.is_false(vim.bo[bufnr].modifiable)
      assert.is_true(vim.wait(10000, function()
        local text =
          table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
        return text:find('CN%s*=%s*leaf.test') ~= nil
      end, 10))
      assert.is_false(vim.bo[bufnr].modified)
      -- Sourced again, the shim keeps one handler per pattern
      vim.cmd.source(h.root .. '/plugin/cert.lua')
      assert.equals(1, #vim.api.nvim_get_autocmds({
        group = 'dy_cert',
        event = 'BufReadPost',
        pattern = '*.der',
      }))
    end)

    it('reads a .cer of bare base64 DER, as Azure exports it', function()
      if not ready then return pending('openssl is not installed') end
      local der = assert(io.open(dir .. '/leaf.der', 'rb')):read('*a')
      vim.fn.writefile({ vim.base64.encode(der) }, dir .. '/fw.cer')
      local text = built(cert, { path = dir .. '/fw.cer' })
      assert.is_truthy(text:find('1 certificate, DER', 1, true))
      assert.is_truthy(text:find('CN%s*=%s*leaf.test'))
      vim.cmd.source(h.root .. '/plugin/cert.lua')
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/fw.cer'))
      local bufnr = vim.api.nvim_get_current_buf()
      assert.equals('nofile', vim.bo[bufnr].buftype)
      assert.is_true(vim.wait(10000, function()
        local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        return table.concat(lines, '\n'):find('CN%s*=%s*leaf.test') ~= nil
      end, 10))
    end)

    it('leaves a PEM file as text to edit', function()
      if not ready then return pending('openssl is not installed') end
      vim.fn.rename(dir .. '/leaf.pem', dir .. '/leaf.crt')
      vim.cmd.source(h.root .. '/plugin/cert.lua')
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/leaf.crt'))
      local bufnr = vim.api.nvim_get_current_buf()
      assert.equals('', vim.bo[bufnr].buftype)
      assert.is_true(vim.bo[bufnr].modifiable)
      assert.equals(
        '-----BEGIN CERTIFICATE-----',
        vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      )
    end)

    --- An `openssl` whose `s_client` answers with the chain of this spec, as
    --- `leaf.test` would serve it, and is the real one otherwise
    local function served(handshake)
      local real = vim.fn.exepath('openssl')
      h.write(dir .. '/bin/openssl', {
        '#!/bin/sh',
        'if [ "$1" = s_client ]; then',
        '  echo "$*" > "' .. dir .. '/s_client"',
        '  echo CONNECTED',
        '  cat "' .. dir .. '/leaf.pem" "' .. dir .. '/ca.pem"',
        "  printf '%s\\n' '" .. handshake .. "'",
        '  exit 0',
        'fi',
        'exec "' .. real .. '" "$@"',
      })
      vim.fn.setfperm(dir .. '/bin/openssl', 'rwxr-xr-x')
      vim.env.PATH = dir .. '/bin:' .. path
    end

    it('reads the chain a host serves, and what its handshake said', function()
      if not ready then return pending('openssl is not installed') end
      served(
        'New, TLSv1.3, Cipher is TLS_AES_256_GCM_SHA384\nVerify return code: 62 (hostname mismatch)'
      )
      local lines
      cert.from_host('leaf.test', 8443, function(out) lines = out end)
      assert.is_true(vim.wait(10000, function() return lines ~= nil end, 10))
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('# leaf.test:8443', 1, true))
      assert.is_truthy(
        text:find('2 certificates, as the host serves them', 1, true)
      )
      assert.is_truthy(
        text:find('each certificate is issued by the next', 1, true)
      )
      assert.is_truthy(
        text:find('- Handshake: TLSv1.3, TLS_AES_256_GCM_SHA384', 1, true)
      )
      assert.is_truthy(
        text:find(
          '- Host name and chain: **fails**: hostname mismatch (62)',
          1,
          true
        )
      )
      -- Before the certificates themselves
      assert.is_truthy(text:find('Handshake.*## Certificate 1 of 2'))
      assert.equals(
        's_client -connect leaf.test:8443 -servername leaf.test -verify_hostname leaf.test -showcerts',
        vim.fn.readfile(dir .. '/s_client')[1]
      )
    end)

    it('checks an address against the IP names, sending no SNI', function()
      if not ready then return pending('openssl is not installed') end
      served('Verify return code: 0 (ok)')
      local lines
      cert.from_host('10.0.0.1', 443, function(out) lines = out end)
      assert.is_true(vim.wait(10000, function() return lines ~= nil end, 10))
      assert.equals(
        's_client -connect 10.0.0.1:443 -verify_ip 10.0.0.1 -showcerts',
        vim.fn.readfile(dir .. '/s_client')[1]
      )
    end)

    it('reads a .crt of text that starts with 0 as no certificate', function()
      h.write(dir .. '/notes.crt', { '0 fingerprint of the old key' })
      assert.is_nil(
        cert.kind(dir .. '/notes.crt', '0 fingerprint of the old key\n')
      )
      vim.cmd.source(h.root .. '/plugin/cert.lua')
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.crt'))
      assert.equals('', vim.bo.buftype)
    end)

    it('reports a file openssl cannot read in one line per line', function()
      if not ready then return pending('openssl is not installed') end
      -- A SEQUENCE of the right length that is no certificate
      local bytes = '\48\3\2\1\0'
      local file = assert(io.open(dir .. '/bad.der', 'wb'))
      file:write(bytes)
      file:close()
      local text = built(cert, { path = dir .. '/bad.der' })
      assert.is_falsy(text:find('\n\n\n', 1, true))
      vim.cmd.source(h.root .. '/plugin/cert.lua')
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/bad.der'))
      local bufnr = vim.api.nvim_get_current_buf()
      assert.is_true(
        vim.wait(
          10000,
          function()
            return not vim.api
              .nvim_buf_get_lines(bufnr, 0, 1, false)[1]
              :find('^Reading')
          end,
          10
        )
      )
    end)

    it('says why a host served no certificate', function()
      if not ready then return pending('openssl is not installed') end
      h.write(dir .. '/bin/openssl', {
        '#!/bin/sh',
        'echo "connect:errno=111" >&2',
        'exit 1',
      })
      vim.fn.setfperm(dir .. '/bin/openssl', 'rwxr-xr-x')
      vim.env.PATH = dir .. '/bin:' .. path
      local lines
      cert.from_host('down.test', 443, function(out) lines = out end)
      assert.is_true(vim.wait(10000, function() return lines ~= nil end, 10))
      assert.same({
        '# down.test:443',
        '',
        'No certificate served: connect:errno=111',
      }, lines)
    end)

    it('reads the certificates among other PEM blocks, and no more', function()
      if not ready then return pending('openssl is not installed') end
      local lines = vim.fn.readfile(dir .. '/leaf.csr')
      vim.list_extend(lines, vim.fn.readfile(dir .. '/leaf.pem'))
      h.write(dir .. '/mixed.pem', lines)
      local text = built(cert, { path = dir .. '/mixed.pem' })
      assert.is_truthy(text:find('1 certificate, PEM', 1, true))
      assert.is_truthy(text:find('- Order: a single certificate', 1, true))
      assert.is_truthy(text:find('CN%s*=%s*leaf.test'))
      assert.is_falsy(text:find('Not all read', 1, true))
    end)

    it('says where a chain is out of order, and what it left out', function()
      if not ready then return pending('openssl is not installed') end
      h.write(
        dir .. '/reversed.pem',
        vim.list_extend(
          vim.fn.readfile(dir .. '/ca.pem'),
          vim.fn.readfile(dir .. '/leaf.pem')
        )
      )
      local text = built(cert, { path = dir .. '/reversed.pem' })
      assert.is_truthy(
        text:find(
          '- Order: Certificate 1 is not issued by certificate 2',
          1,
          true
        )
      )
      cert.MAX_CERTS = 1
      text = built(cert, { path = dir .. '/chain.pem' })
      assert.is_truthy(
        text:find('2 certificates, PEM; the first 1 are shown', 1, true)
      )
      assert.is_truthy(text:find('## Certificate 1 of 1', 1, true))
      assert.is_falsy(text:find('## Certificate 2', 1, true))
    end)

    it('gives the first line of a verify failure it cannot read', function()
      if not ready then return pending('openssl is not installed') end
      local real = vim.fn.exepath('openssl')
      h.write(dir .. '/bin/openssl', {
        '#!/bin/sh',
        'if [ "$1" = verify ]; then',
        '  printf "store unreadable\\nmore\\n" >&2',
        '  exit 2',
        'fi',
        'exec "' .. real .. '" "$@"',
      })
      vim.fn.setfperm(dir .. '/bin/openssl', 'rwxr-xr-x')
      vim.env.PATH = dir .. '/bin:' .. path
      local text = built(cert, { path = dir .. '/leaf.pem' })
      assert.is_truthy(
        text:find('- Trust: **fails**: store unreadable\n', 1, true)
      )
    end)
  end)

  describe('hosts', function()
    it('reads a host and its port, nothing that reads as an option', function()
      assert.same({ 'example.com', 443 }, { cert.parse_host('example.com') })
      assert.same(
        { 'example.com', 8443 },
        { cert.parse_host('https://user@example.com:8443/x?y') }
      )
      assert.same({ 'a.example', 80 }, { cert.parse_host('http://a.example/') })
      assert.same({ 'a.example', 443 }, { cert.parse_host('"a.example",') })
      assert.is_nil(cert.parse_host('-connect'))
      assert.is_nil(cert.parse_host('localhost'))
      assert.is_nil(cert.parse_host('a..b'))
      assert.is_nil(cert.parse_host('a.example:99999'))
    end)

    it(
      'reads what a handshake said',
      function()
        assert.same(
          {
            protocol = 'TLSv1.2',
            cipher = 'ECDHE-RSA-AES128-GCM-SHA256',
            verify = 'OK, the chain and the host name',
          },
          cert.handshake(table.concat({
            'New, TLSv1.2, Cipher is ECDHE-RSA-AES128-GCM-SHA256',
            'Verify return code: 0 (ok)',
          }, '\n'))
        )
      end
    )

    it('says when the cursor is on no host', function()
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      h.buffer({ lines = { 'nothing here' } })
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'nothing here' } }))
      local done = false
      cert.host(nil, function() done = true end)
      restore()
      assert.is_true(done)
      assert.same({ 'No host name under the cursor' }, notes)
    end)

    --- `util.system.run` answering `s_client` with no certificate, and the
    --- commands it was asked to run
    local function no_answer()
      local ran = {}
      local system = require('util.system')
      local restore = h.stub(system, 'run', function(cmd, _, on_done)
        table.insert(ran, cmd)
        on_done({ code = 1, stdout = '', stderr = 'connect:errno=61' })
      end)
      return ran, restore
    end

    it('asks the host it is given, and shows what it said', function()
      local notes = {}
      local restore_notify = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      local ran, restore = no_answer()
      local done = false
      cert.host('https://example.com:8443/x', function() done = true end)
      restore()
      restore_notify()
      assert.is_true(done)
      assert.same({ 'Asking example.com:8443 for its certificates…' }, notes)
      assert.equals('example.com:8443', ran[1][4])
      assert.same({
        '# example.com:8443',
        '',
        'No certificate served: connect:errno=61',
      }, vim.api.nvim_buf_get_lines(0, 0, -1, false))
      assert.equals('markdown', vim.bo.filetype)
    end)

    it('reads the value of a key the cursor is on', function()
      local restore_notify = h.stub(vim, 'notify', function() end)
      local ran, restore = no_answer()
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'host: a.example' } }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      local done = false
      cert.host(nil, function() done = true end)
      restore()
      restore_notify()
      assert.is_true(done)
      assert.equals('a.example:443', ran[1][4])
    end)
  end)

  describe('the command', function()
    it('runs `host` on the host it is given', function()
      local got
      local restore = h.stub(cert, 'host', function(target) got = target end)
      cert.command({ fargs = { 'host', 'example.com' } })
      restore()
      assert.equals('example.com', got)
    end)

    it('reads the file it is given, a space in its name too', function()
      h.write(dir .. '/my notes.txt', { 'hello' })
      cert.command({ fargs = { dir .. '/my', 'notes.txt' } })
      assert.same(
        { '# my notes.txt', '', 'No certificate in this file' },
        vim.api.nvim_buf_get_lines(0, 0, -1, false)
      )
      assert.is_false(vim.bo.modifiable)
    end)

    it('reads the file of a buffer that holds no PEM text', function()
      h.write(dir .. '/bundle.p12', { 'x' })
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/bundle.p12'))
      local bufnr = vim.api.nvim_get_current_buf()
      cert.command({ fargs = {} })
      assert.are_not.equal(bufnr, vim.api.nvim_get_current_buf())
      local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
      assert.equals('# bundle.p12', lines[1])
      assert.is_truthy(lines[3]:find('PKCS#12', 1, true))
    end)

    it('says when a buffer holds no certificate and is no file', function()
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg, level }) end
      )
      local bufnr = h.buffer({ lines = { 'nothing here' } })
      vim.api.nvim_set_current_buf(bufnr)
      cert.command({ fargs = {} })
      restore()
      assert.same(
        { { 'No certificate in this buffer', vim.log.levels.WARN } },
        notes
      )
      assert.equals(bufnr, vim.api.nvim_get_current_buf())
    end)
  end)

  it('says why a file is not read', function()
    assert.same({ nil, dir .. ' is not a file' }, { cert.read_file(dir) })
    h.write(dir .. '/big.pem', { 'some text' })
    cert.LIMIT = 4
    assert.same(
      { nil, 'big.pem is larger than 0 KiB: no certificate file' },
      { cert.read_file(dir .. '/big.pem') }
    )
  end)
end)
