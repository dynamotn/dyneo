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
    assert.equals('der', cert.kind('a.cer', '\48\130\1\10'))
    assert.equals('pkcs7', cert.kind('a.P7B', '\48\130\1\10'))
    assert.equals('pkcs12', cert.kind('a.pfx', '\48\130\1\10'))
    assert.is_nil(cert.kind('a.crt', 'hello'))
  end)

  it('unwraps DER written as bare base64, and nothing else', function()
    local der = '\48\130\1\10abc'
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
    vim.fn.writefile({ '\48\130\1\10' }, dir .. '/a.der', 'b')
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
  end)
end)
