local h = require('helpers')
local sensitive = require('util.sensitive')

describe('util.sensitive', function()
  local dir, cleanup
  before_each(function()
    dir, cleanup = h.tmpdir()
  end)
  after_each(function() cleanup() end)

  describe('is_sensitive_path', function()
    it(
      'is false for an empty path',
      function() assert.is_false(sensitive.is_sensitive_path('')) end
    )

    for _, name in ipairs({
      '.env',
      'prod.env',
      '.env.local',
      '.envrc',
      'token.age',
      'note.gpg',
      'cert.pem',
      'server.key',
      'store.p12',
      'store.pfx',
      'id_rsa',
      'id_ed25519',
      '.netrc',
      '_netrc',
      '.pgpass',
      '.git-credentials',
      '.npmrc',
      '.pypirc',
      '.vault-token',
      '.gitlab.nvim',
      'putty.ppk',
      'AuthKey_ABC123.p8',
      'release.jks',
      'debug.keystore',
      'vault.kdbx',
      '.htpasswd',
      'kubeconfig',
      'kubeconfig.yaml',
      'prod.kubeconfig',
      'application_default_credentials.json',
      'credentials.tfrc.json',
      'terraform.tfstate',
      'terraform.tfstate.backup',
      'ID_RSA',
      '.ENV',
      'Server.KEY',
    }) do
      it(
        'flags a file named ' .. name,
        function()
          assert.is_true(sensitive.is_sensitive_path(dir .. '/' .. name))
        end
      )
    end

    for _, name in ipairs({
      'init.lua',
      'environment.md',
      'id_rsa.pub',
      'keymap.lua',
      'envrc.example',
      'terraform.tfvars',
      'kubeconfig.go',
      'credentials.toml',
      'credentials',
    }) do
      it(
        'leaves an ordinary file named ' .. name,
        function()
          assert.is_false(sensitive.is_sensitive_path(dir .. '/' .. name))
        end
      )
    end

    for _, sub in ipairs({
      '.ssh',
      '.gnupg',
      '.aws',
      '.kube',
      '.docker',
      'secrets',
    }) do
      it(
        'flags any file below a ' .. sub .. ' directory',
        function()
          assert.is_true(
            sensitive.is_sensitive_path(dir .. '/' .. sub .. '/deep/config')
          )
        end
      )
    end

    for _, sub in ipairs({ '.ssh', '.aws', 'secrets', '.password-store' }) do
      it('flags a ' .. sub .. ' directory itself', function()
        assert.is_true(sensitive.is_sensitive_path(dir .. '/' .. sub))
        assert.is_true(sensitive.is_sensitive_path(dir .. '/' .. sub .. '/'))
      end)
    end

    it('flags a sensitive directory in another case', function()
      assert.is_true(sensitive.is_sensitive_path(dir .. '/.SSH/config'))
      assert.is_true(sensitive.is_sensitive_path(dir .. '/Secrets/x.yaml'))
    end)

    for _, rel in ipairs({
      '.cargo/credentials.toml',
      '.cargo/credentials',
      '.gem/credentials',
    }) do
      it(
        'flags ' .. rel .. ' by where it is',
        function()
          assert.is_true(sensitive.is_sensitive_path(dir .. '/' .. rel))
        end
      )
    end

    it('flags the secrets submodule by its full path', function()
      local path = vim.fs.joinpath(vim.env.HOME, 'Dotfiles', 'secrets', 'data')
      assert.is_true(sensitive.is_sensitive_path(path))
    end)

    it('resolves a relative path against the working directory', function()
      local cwd = vim.fn.getcwd()
      vim.cmd.cd(dir)
      local ok, result = pcall(sensitive.is_sensitive_path, '.env')
      vim.cmd.cd(cwd)
      assert.is_true(ok)
      assert.is_true(result)
    end)

    it('follows a symlink into a sensitive place', function()
      h.write(dir .. '/secrets/token', { 'x' })
      assert(vim.uv.fs_symlink(dir .. '/secrets/token', dir .. '/innocent'))
      assert.is_true(sensitive.is_sensitive_path(dir .. '/innocent'))
    end)

    it('does not flag a symlink to an ordinary file', function()
      h.write(dir .. '/plain.txt', { 'x' })
      assert(vim.uv.fs_symlink(dir .. '/plain.txt', dir .. '/link.txt'))
      assert.is_false(sensitive.is_sensitive_path(dir .. '/link.txt'))
    end)
  end)

  describe('is_secret_key', function()
    for _, key in ipairs({
      'PASSWORD',
      'db_passwd',
      'ssh_passphrase',
      'client_secret',
      'GITHUB_TOKEN',
      'aws credential file',
      'apiKey',
      'api_key',
      'access-key',
      'privateKey',
    }) do
      it(
        'names ' .. key .. ' as a secret',
        function() assert.is_true(sensitive.is_secret_key(key)) end
      )
    end

    for _, key in ipairs({ 'name', 'replicas', 'image', 'keyboard' }) do
      it(
        'leaves ' .. key .. ' alone',
        function() assert.is_false(sensitive.is_secret_key(key)) end
      )
    end

    it('copes with nothing to look at', function()
      assert.is_false(sensitive.is_secret_key(nil))
      assert.is_false(sensitive.is_secret_key(''))
    end)
  end)

  describe('secret_format', function()
    it('names the format a value has the shape of', function()
      assert.are.equal(
        'GitHub token',
        sensitive.secret_format('ghp_0123456789abcdefghij')
      )
      assert.are.equal(
        'AWS access key',
        sensitive.secret_format('AKIAIOSFODNN7EXAMPLE')
      )
    end)

    it('names a private key held in base64', function()
      for _, header in ipairs({
        'RSA PRIVATE KEY',
        'PRIVATE KEY',
        'EC PRIVATE KEY',
        'OPENSSH PRIVATE KEY',
        'ENCRYPTED PRIVATE KEY',
      }) do
        local line = '  client-key-data: '
          .. vim.base64.encode(('-----BEGIN %s-----\nMIIE'):format(header))
        assert.are.equal(
          'base64 private key',
          sensitive.secret_format(line),
          header
        )
      end
    end)

    it('leaves a certificate held in base64', function()
      local line = 'certificate-authority-data: '
        .. vim.base64.encode('-----BEGIN CERTIFICATE-----\nMIIC')
      assert.is_nil(sensitive.secret_format(line))
    end)

    it('says nothing about an ordinary value', function()
      assert.is_nil(sensitive.secret_format('nginx:1.27'))
      -- A token's prefix in ordinary code
      assert.is_nil(sensitive.secret_format('hf_hub_download(repo_id)'))
      assert.is_nil(sensitive.secret_format('echo $npm_package_version'))
      assert.is_nil(sensitive.secret_format('ghs_check = true'))
      assert.is_nil(sensitive.secret_format(nil))
    end)
  end)

  describe('is_sensitive', function()
    it('flags a buffer by its filetype', function()
      local bufnr = h.buffer({ filetype = 'gitcommit' })
      assert.is_true(sensitive.is_sensitive(bufnr))
    end)

    it('flags a buffer by its name', function()
      local bufnr = h.buffer({ name = dir .. '/.env' })
      assert.is_true(sensitive.is_sensitive(bufnr))
    end)

    it('resolves the path of a buffer once, not on every question', function()
      h.write(dir .. '/main.lua', { 'a' })
      local bufnr = h.buffer({ name = dir .. '/main.lua', lines = { 'a' } })
      local calls = 0
      local realpath = vim.uv.fs_realpath
      local restore = h.stub(vim.uv, 'fs_realpath', function(...)
        calls = calls + 1
        return realpath(...)
      end)
      sensitive.is_sensitive(bufnr)
      sensitive.is_sensitive(bufnr)
      restore()
      assert.are.equal(1, calls)
    end)

    it('asks again about a name that had no file behind it', function()
      local bufnr = h.buffer({ name = dir .. '/notes.txt', lines = { 'a' } })
      assert.is_false(sensitive.is_sensitive(bufnr))
      h.write(dir .. '/id_rsa', { 'key' })
      vim.uv.fs_symlink(dir .. '/id_rsa', dir .. '/notes.txt')
      assert.is_true(sensitive.is_sensitive(bufnr))
    end)

    it('asks about the current buffer for nil and 0', function()
      local bufnr = h.buffer({ name = dir .. '/id_rsa' })
      vim.api.nvim_set_current_buf(bufnr)
      assert.is_true(sensitive.is_sensitive())
      assert.is_true(sensitive.is_sensitive(0))
    end)

    it(
      'is false for an unnamed buffer',
      function() assert.is_false(sensitive.is_sensitive(h.buffer())) end
    )

    for name, line in pairs({
      -- Spelt in pieces: the `detect-private-key` hook reads this file too,
      -- and a header written out whole would fail the commit.
      ['a private key'] = '-----BEGIN OPENSSH ' .. 'PRIVATE KEY' .. '-----',
      ['an AWS key'] = 'aws_access_key_id = AKIAIOSFODNN7EXAMPLE',
      ['a GitHub token'] = 'GH_TOKEN=ghp_0123456789abcdefghijklmnopqrstuvwx',
      ['a GitLab token'] = 'token: glpat-0123456789abcdefghij',
      ['a Slack token'] = 'SLACK=xoxb-123456789012-abcdefghijkl',
      ['an Anthropic key'] = 'key = "sk-ant-api03-abcdefghijklmnop"',
      ['a Google key'] = 'apiKey: AIzaSyA0123456789abcdefghijklmnopqrstu',
      ['a JSON Web Token'] = 'auth: eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.sig',
      ['a password in a URL'] = 'url = https://admin:hunter2@example.com/db',
    }) do
      it('flags a buffer holding ' .. name, function()
        local bufnr =
          h.buffer({ name = dir .. '/values.yaml', lines = { line } })
        assert.is_true(sensitive.is_sensitive(bufnr))
      end)
    end

    for name, line in pairs({
      ['an ordinary assignment'] = 'password = get_password()',
      ['a word ending in sk-'] = 'local risk = "risk-free"',
      ['a key name without a value'] = 'aws_access_key_id = ""',
    }) do
      it('leaves a buffer holding ' .. name, function()
        local bufnr = h.buffer({ name = dir .. '/main.lua', lines = { line } })
        assert.is_false(sensitive.is_sensitive(bufnr))
      end)
    end

    it('names the filetype and the path that hold a buffer back', function()
      local commit = h.buffer({
        name = dir .. '/.git/COMMIT_EDITMSG',
        filetype = 'gitcommit',
      })
      assert.are.same({ 'filetype gitcommit' }, sensitive.reasons(commit))
      local env = h.buffer({ name = dir .. '/prod.env' })
      local reasons = sensitive.reasons(env)
      assert.are.equal(1, #reasons)
      assert.is_truthy(reasons[1]:match('^path .*prod%.env$'))
    end)

    it('says what it found and where', function()
      local bufnr = h.buffer({
        name = dir .. '/main.lua',
        lines = { 'local a = 1', 'local token = "ghp_0123456789abcdefghij"' },
      })
      assert.are.same({ 'GitHub token on line 2' }, sensitive.reasons(bufnr))
    end)

    it('reads the buffer again only once it has changed', function()
      local bufnr = h.buffer({ name = dir .. '/main.lua', lines = { 'clean' } })
      assert.is_false(sensitive.is_sensitive(bufnr))
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        'token = "ghp_0123456789abcdefghij"',
      })
      assert.is_true(sensitive.is_sensitive(bufnr))
    end)

    it(
      'follows lines added, removed and changed after the first read',
      function()
        local token = 'token = "ghp_0123456789abcdefghij"'
        local bufnr = h.buffer({
          name = dir .. '/main.lua',
          lines = { 'a', 'b', 'c', 'd' },
        })
        assert.are.same({}, sensitive.reasons(bufnr))
        -- Two lines in, one of them a token: it moves the rest down
        vim.api.nvim_buf_set_lines(bufnr, 1, 1, false, { 'x', token })
        assert.are.same({ 'GitHub token on line 3' }, sensitive.reasons(bufnr))
        -- The lines above it go: the token moves up with what follows
        vim.api.nvim_buf_set_lines(bufnr, 0, 2, false, {})
        assert.are.same({ 'GitHub token on line 1' }, sensitive.reasons(bufnr))
        -- A token typed into the last line, and the first one taken out
        vim.api.nvim_buf_set_text(bufnr, 3, 1, 3, 1, { ' ' .. token })
        vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'clean' })
        assert.are.same({ 'GitHub token on line 4' }, sensitive.reasons(bufnr))
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'clean' })
        assert.is_false(sensitive.is_sensitive(bufnr))
      end
    )

    it('holds back a buffer too large to search', function()
      local config = require('config.sensitive')
      local before = config.content_max_bytes
      config.content_max_bytes = 16
      local bufnr = h.buffer({
        name = dir .. '/main.lua',
        lines = { 'nothing secret here', 'nor here' },
      })
      local held = sensitive.is_sensitive(bufnr)
      local reasons = sensitive.reasons(bufnr)
      sensitive.allow(bufnr)
      local waived = sensitive.is_sensitive(bufnr)
      config.content_max_bytes = before
      assert.is_true(held)
      assert.is_truthy(reasons[1]:find('too large to search', 1, true))
      assert.is_false(waived)
    end)

    --- Leave a `betterleaks` finding on `bufnr`, as the linter would
    ---@param bufnr integer
    local function leak(bufnr)
      -- nvim-lint's namespace for the linter, named after it
      vim.diagnostic.set(vim.api.nvim_create_namespace('betterleaks'), bufnr, {
        {
          lnum = 2,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          source = 'betterleaks',
          code = 'generic-api-key',
          message = 'Detected a generic API key',
        },
      })
    end

    it(
      'looks for the betterleaks namespace once per diagnostics change',
      function()
        -- Forget whatever an earlier spec left cached
        vim.api.nvim_exec_autocmds('DiagnosticChanged', {})
        local calls = 0
        local get = vim.api.nvim_get_namespaces
        local restore = h.stub(vim.api, 'nvim_get_namespaces', function()
          calls = calls + 1
          local namespaces = get()
          namespaces.betterleaks = nil
          return namespaces
        end)
        local bufnr = h.buffer({ lines = { 'a' } })
        sensitive.is_sensitive(bufnr)
        sensitive.is_sensitive(bufnr)
        local before = calls
        vim.api.nvim_exec_autocmds('DiagnosticChanged', {})
        sensitive.is_sensitive(bufnr)
        restore()
        assert.are.equal(1, before)
        assert.are.equal(2, calls)
      end
    )

    it('flags a buffer betterleaks has found something in', function()
      local bufnr =
        h.buffer({ name = dir .. '/main.lua', lines = { 'a', 'b', 'c' } })
      assert.is_false(sensitive.is_sensitive(bufnr))
      leak(bufnr)
      assert.is_true(sensitive.is_sensitive(bufnr))
      assert.are.same(
        { 'betterleaks generic-api-key on line 3' },
        sensitive.reasons(bufnr)
      )
    end)

    it('waives a betterleaks finding along with the patterns', function()
      local bufnr =
        h.buffer({ name = dir .. '/main.lua', lines = { 'a', 'b', 'c' } })
      leak(bufnr)
      sensitive.allow(bufnr)
      assert.is_false(sensitive.is_sensitive(bufnr))
    end)

    it('takes a waiver back again', function()
      local bufnr = h.buffer({
        name = dir .. '/main.lua',
        lines = { 'token = "ghp_0123456789abcdefghij"' },
      })
      sensitive.allow(bufnr)
      assert.is_false(sensitive.is_sensitive(bufnr))
      sensitive.allow(bufnr, false)
      assert.is_false(sensitive.is_allowed(bufnr))
      assert.is_true(sensitive.is_sensitive(bufnr))
    end)

    it('says what a waived buffer would be held back for', function()
      local bufnr = h.buffer({
        name = dir .. '/main.lua',
        lines = { 'token = "ghp_0123456789abcdefghij"' },
      })
      sensitive.allow(bufnr)
      assert.are.same({}, sensitive.reasons(bufnr))
      assert.are.same(
        { 'GitHub token on line 1' },
        sensitive.reasons(bufnr, { ignore_waiver = true })
      )
    end)

    it('lets a buffer through once it is allowed, but never a .env', function()
      local scratch = h.buffer({
        name = dir .. '/main.lua',
        lines = { 'token = "ghp_0123456789abcdefghij"' },
      })
      sensitive.allow(scratch)
      assert.is_false(sensitive.is_sensitive(scratch))

      local secret = h.buffer({ name = dir .. '/.env', lines = { 'A=1' } })
      sensitive.allow(secret)
      assert.is_true(sensitive.is_sensitive(secret))
    end)

    it('is false for an invalid buffer', function()
      local bufnr = h.buffer()
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_false(sensitive.is_sensitive(bufnr))
    end)

    it('holds back a marked buffer, whatever is waived', function()
      local bufnr =
        h.buffer({ name = dir .. '/values.yaml', lines = { 'a: 1' } })
      assert.is_false(sensitive.is_sensitive(bufnr))
      sensitive.mark(bufnr, 'decrypted with sops')
      sensitive.allow(bufnr)
      assert.is_true(sensitive.is_sensitive(bufnr))
      assert.equals('decrypted with sops', sensitive.marked(bufnr))
      assert.same({ 'decrypted with sops' }, sensitive.reasons(bufnr))
    end)
  end)
end)
