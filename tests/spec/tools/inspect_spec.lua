local h = require('helpers')

--- base64url of `text`, without padding
local function b64url(text)
  return (vim.base64.encode(text):gsub('=+$', ''):gsub('+', '-'):gsub('/', '_'))
end

--- The label of a private key block, put together so that no line of this
--- file looks like a key to the secret scanners: the fixtures hold none
local KEY = 'PRIVATE' .. ' KEY'

local function token(header, claims)
  return b64url(vim.json.encode(header))
    .. '.'
    .. b64url(vim.json.encode(claims))
    .. '.c2lnbmF0dXJl'
end

describe('tools.inspect', function()
  local inspect, dir, cleanup

  before_each(function()
    h.unload('tools.inspect', 'util.scratch')
    inspect = require('tools.inspect')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    vim.diagnostic.reset()
    cleanup()
  end)

  it('decodes base64 and base64url, padded or not', function()
    assert.equals('{"a":1}', inspect.base64(b64url('{"a":1}')))
    assert.equals('hi', inspect.base64('aGk='))
    assert.is_nil(inspect.base64('a'))
  end)

  describe('jwt', function()
    local jwt = token(
      { alg = 'HS256', typ = 'JWT' },
      { sub = 'me', exp = 100, iat = 50 }
    )

    it('finds the token under the cursor, or the first of the line', function()
      local line = 'Authorization: Bearer ' .. jwt .. ' and ' .. jwt .. 'x'
      assert.equals(jwt, inspect.jwt_at(line, 30))
      assert.equals(jwt, inspect.jwt_at(line))
      assert.is_nil(inspect.jwt_at('no token here'))
    end)

    it('shows header, claims and times, never the signature', function()
      local lines = assert(inspect.jwt(jwt, 200))
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('"alg": "HS256"', 1, true))
      assert.is_truthy(text:find('"sub": "me"', 1, true))
      assert.is_truthy(text:find('- exp: 1970-01-01 00:01:40 UTC', 1, true))
      assert.is_truthy(text:find('**expired**', 1, true))
      assert.is_falsy(text:find('c2lnbmF0dXJl', 1, true))
      assert.is_truthy(
        table
          .concat(assert(inspect.jwt(jwt, 40)), '\n')
          :find('valid for 1 more minutes', 1, true)
      )
      assert.is_nil(inspect.jwt('eyJx.eyJy.z'))
    end)
  end)

  describe('pem', function()
    local PEM = {
      'tls:',
      '  cert: |',
      '    -----BEGIN CERTIFICATE-----',
      '    MIIB',
      '    -----END CERTIFICATE-----',
      'key: -----BEGIN ' .. KEY .. '-----',
      'abc',
      '-----END ' .. KEY .. '-----',
    }

    it('finds plain and base64 blocks, by label', function()
      local encoded = vim.base64.encode(
        '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----\n'
      )
      local found = inspect.pems(
        vim.list_extend(vim.deepcopy(PEM), { '  tls.crt: ' .. encoded })
      )
      assert.equals(3, #found)
      assert.same(
        { 'CERTIFICATE', 3, 5 },
        { found[1].label, found[1].first, found[1].last }
      )
      assert.equals(
        '-----BEGIN CERTIFICATE-----\nMIIB\n-----END CERTIFICATE-----',
        found[1].text
      )
      assert.equals(
        '-----BEGIN ' .. KEY .. '-----\nabc\n-----END ' .. KEY .. '-----',
        found[2].text
      )
      assert.same(
        { 'CERTIFICATE', 9, 9 },
        { found[3].label, found[3].first, found[3].last }
      )
    end)

    it('names a private key, never decodes it', function()
      local lines
      inspect.pem({
        kind = 'pem',
        label = 'PRIVATE KEY',
        text = 'x',
        first = 1,
        last = 1,
      }, function(out) lines = out end)
      assert.same({
        '# PRIVATE KEY',
        '',
        'A private key: it is not decoded or shown here.',
      }, lines)
    end)

    describe('with openssl', function()
      local cert
      before_each(function()
        if vim.fn.executable('openssl') ~= 1 then
          -- On every CI runner: missing there, these cases would test nothing
          assert(not vim.env.CI, 'no openssl on CI')
          return
        end
        local result = vim
          .system({
            'openssl',
            'req',
            '-x509',
            '-newkey',
            'ec',
            '-pkeyopt',
            'ec_paramgen_curve:prime256v1',
            '-nodes',
            '-days',
            '1',
            '-subj',
            '/CN=inspect.test',
            '-keyout',
            dir .. '/key.pem',
            '-out',
            dir .. '/cert.pem',
          }, { text = true })
          :wait()
        assert.equals(0, result.code, result.stderr)
        cert = vim.fn.readfile(dir .. '/cert.pem')
      end)

      it(
        'reads a certificate under the cursor into a held back buffer',
        function()
          if not cert then return pending('openssl is not installed') end
          local bufnr =
            h.buffer({ lines = vim.list_extend({ 'cert: |' }, cert) })
          vim.api.nvim_set_current_buf(bufnr)
          vim.api.nvim_win_set_cursor(0, { 3, 0 })
          inspect.command({ fargs = {} })
          -- Read off the main loop: the buffer opens when openssl answers
          assert.are.equal(bufnr, vim.api.nvim_get_current_buf())
          assert.is_true(
            vim.wait(
              5000,
              function() return vim.api.nvim_get_current_buf() ~= bufnr end,
              10
            )
          )
          local out = vim.api.nvim_get_current_buf()
          assert.is_truthy(require('util.sensitive').marked(out))
          local text =
            table.concat(vim.api.nvim_buf_get_lines(out, 0, -1, false), '\n')
          assert.is_truthy(text:find('CN%s*=%s*inspect.test'))
          assert.is_truthy(text:find('notAfter=', 1, true))
        end
      )

      it('warns on a certificate ending within the window', function()
        if not cert then return pending('openssl is not installed') end
        local bufnr = h.buffer({ lines = vim.list_extend({ 'a: 1' }, cert) })
        local notes = {}
        local restore = h.stub(
          vim,
          'notify',
          function(msg) table.insert(notes, msg) end
        )
        inspect.check_expiry(bufnr)
        assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
        restore()
        local diagnostics = vim.diagnostic.get(bufnr)
        assert.equals(1, #diagnostics)
        assert.equals(1, diagnostics[1].lnum)
        assert.equals(vim.diagnostic.severity.WARN, diagnostics[1].severity)
      end)
    end)

    it('errs on an expired certificate', function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      -- An openssl for which every certificate ended long ago
      h.write(dir .. '/bin/openssl', {
        '#!/bin/sh',
        'cat > /dev/null',
        'case "$*" in',
        '  *-enddate*) echo "notAfter=Jan  1 00:00:00 2020 GMT";;',
        '  *-checkend*) exit 1;;',
        'esac',
      })
      vim.fn.setfperm(dir .. '/bin/openssl', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      local bufnr = h.buffer({ lines = PEM })
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      inspect.check_expiry(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
      restore()
      vim.env.PATH = path
      local diagnostics = vim.diagnostic.get(bufnr)
      assert.equals(1, #diagnostics)
      assert.equals(2, diagnostics[1].lnum)
      assert.equals(
        'Certificate expired on Jan  1 00:00:00 2020 GMT',
        diagnostics[1].message
      )
    end)
  end)

  it('counts a certificate openssl cannot answer for as unchecked', function()
    vim.fn.mkdir(dir .. '/bin', 'p')
    -- Reads the end date, then fails the check with neither 0 nor 1
    h.write(dir .. '/bin/openssl', {
      '#!/bin/sh',
      'cat > /dev/null',
      'case "$*" in',
      '  *-enddate*) echo "notAfter=Jan  1 00:00:00 2030 GMT";;',
      '  *-checkend*) exit 2;;',
      'esac',
    })
    vim.fn.setfperm(dir .. '/bin/openssl', 'rwxr-xr-x')
    local path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    local bufnr = h.buffer({
      lines = {
        '-----BEGIN CERTIFICATE-----',
        'x',
        '-----END CERTIFICATE-----',
      },
    })
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    inspect.check_expiry(bufnr)
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    restore()
    vim.env.PATH = path
    assert.equals(
      '0 certificates checked, 0 expired or ending soon, 1 could not be checked',
      notes[1]
    )
    local diagnostics = vim.diagnostic.get(bufnr)
    assert.equals(1, #diagnostics)
    assert.equals('Certificate could not be checked', diagnostics[1].message)
  end)

  it('sets nothing on a buffer edited while it checked', function()
    vim.fn.mkdir(dir .. '/bin', 'p')
    h.write(dir .. '/bin/openssl', {
      '#!/bin/sh',
      'cat > /dev/null',
      'sleep 0.2',
      'case "$*" in',
      '  *-enddate*) echo "notAfter=Jan  1 00:00:00 2020 GMT";;',
      '  *-checkend*) exit 1;;',
      'esac',
    })
    vim.fn.setfperm(dir .. '/bin/openssl', 'rwxr-xr-x')
    local path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    local bufnr = h.buffer({
      lines = {
        '-----BEGIN CERTIFICATE-----',
        'x',
        '-----END CERTIFICATE-----',
      },
    })
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    inspect.check_expiry(bufnr)
    vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '# moved' })
    assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
    restore()
    vim.env.PATH = path
    assert.equals('The buffer changed meanwhile: check again', notes[1])
    assert.same({}, vim.diagnostic.get(bufnr))
  end)

  it('says when nothing is under the cursor', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'nothing' } }))
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    inspect.command({ fargs = {} })
    inspect.command({ fargs = { 'nope' } })
    restore()
    assert.same({
      'No certificate, key or JWT under the cursor',
      'Unknown subcommand: nope',
    }, notes)
  end)
end)
