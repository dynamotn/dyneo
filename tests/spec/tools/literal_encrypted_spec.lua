local h = require('helpers')

describe('tools.encrypted', function()
  local encrypted, dir, cleanup, path, notes, restore_notify, log

  --- An executable `name` in the scratch bin directory
  local function tool(name, lines)
    local file = dir .. '/bin/' .. name
    h.write(
      file,
      vim.list_extend(
        { '#!/bin/sh', 'echo "' .. name .. ' $*" >> "' .. log .. '"' },
        lines
      )
    )
    vim.fn.setfperm(file, 'rwxr-xr-x')
  end

  before_each(function()
    h.unload('tools.encrypted')
    encrypted = require('tools.encrypted')
    dir, cleanup = h.tmpdir()
    log = dir .. '/calls.log'
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )

    -- Each fake keeps the clear text behind a prefix: `plain: ` for sops,
    -- `enc:` under a vault header, `age:` for chezmoi
    tool('sops', {
      'case "$1" in',
      '  decrypt) sed -n "s/^plain: //p" "$2";;',
      '  edit) t=$(mktemp); sed -n "s/^plain: //p" "$2" > "$t"; cp "$t" "$t.orig"',
      '        $SOPS_EDITOR "$t"',
      '        if cmp -s "$t" "$t.orig"; then exit 200; fi',
      '        { sed "s/^/plain: /" "$t"; echo "x: ENC[AES256_GCM,data:x]"; echo "sops:"; } > "$2";;',
      'esac',
    })
    tool('ansible-vault', {
      'case "$1" in',
      '  decrypt) sed 1d "$4" | sed "s/^enc://";;',
      '  encrypt) { echo "\\$ANSIBLE_VAULT;1.1;AES256"; sed "s/^/enc:/" "$4"; } > "$3";;',
      'esac',
    })
    tool('chezmoi', {
      'case "$1" in',
      '  decrypt) sed "s/^age://" "$2";;',
      '  encrypt) sed "s/^/age:/" "$4" > "$3";;',
      'esac',
    })
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function calls() return vim.fn.readfile(log) end

  --- Decrypt `bufnr` and wait until it is done
  local function decrypt(bufnr)
    local decrypted
    encrypted.open(bufnr, function(ok) decrypted = ok end)
    assert.is_true(vim.wait(5000, function() return decrypted ~= nil end, 10))
    return decrypted
  end

  --- Open `file` the way the BufReadPost hook does
  local function open(file)
    vim.cmd.edit(file)
    local bufnr = vim.api.nvim_get_current_buf()
    return bufnr, decrypt(bufnr)
  end

  describe('kind', function()
    it('tells sops by its values and its metadata', function()
      assert.equals(
        'sops',
        encrypted.kind({ 'a: ENC[AES256_GCM,data:x]', 'sops:', '  mac: x' })
      )
      assert.equals(
        'sops',
        encrypted.kind({
          '{',
          '  "a": "ENC[AES256_GCM,data:x]",',
          '  "sops": {',
        })
      )
      assert.equals(
        'sops',
        encrypted.kind({ 'A=ENC[AES256_GCM,data:x]', 'sops_version=3.9.0' })
      )
      assert.is_nil(
        encrypted.kind({ 'note: ENC[AES256_GCM, is how sops writes it' })
      )
    end)

    it('tells Ansible Vault by its header, chezmoi by its file name', function()
      assert.equals(
        'ansible',
        encrypted.kind({ '$ANSIBLE_VAULT;1.1;AES256', '6162' })
      )
      assert.equals(
        'chezmoi',
        encrypted.kind({ 'anything' }, '/s/encrypted_private_dot_netrc.age')
      )
      assert.equals('chezmoi', encrypted.kind({}, '/s/encrypted_dot_key.asc'))
      assert.is_nil(encrypted.kind({ 'x' }, '/s/private_dot_netrc.age'))
      assert.equals(
        'prod',
        encrypted.vault_id('$ANSIBLE_VAULT;1.2;AES256;prod')
      )
      assert.is_nil(encrypted.vault_id('$ANSIBLE_VAULT;1.1;AES256'))
    end)
  end)

  it('opens sops in the clear, and writes it back through sops edit', function()
    local file = dir .. '/values.yaml'
    h.write(
      file,
      { 'plain: password: hunter2', 'x: ENC[AES256_GCM,data:x]', 'sops:' }
    )
    local bufnr, decrypted = open(file)

    assert.is_true(decrypted)
    assert.same(
      { 'password: hunter2' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    assert.is_true(require('util.sensitive').is_sensitive(bufnr))
    assert.is_false(vim.bo[bufnr].swapfile)
    assert.is_false(vim.bo[bufnr].undofile)
    assert.is_false(vim.bo[bufnr].modified)

    -- No undoing back to the ciphertext
    vim.cmd('silent! undo')
    assert.same(
      { 'password: hunter2' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )

    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'password: changed' })
    vim.cmd('write')
    assert.is_false(vim.bo[bufnr].modified)
    assert.same(
      { 'plain: password: changed', 'x: ENC[AES256_GCM,data:x]', 'sops:' },
      vim.fn.readfile(file)
    )
    assert.equals('sops edit ' .. file, calls()[2])
    assert.equals('Written, encrypted with sops', notes[#notes])
  end)

  it('takes sops leaving an unchanged file alone as written', function()
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr = open(file)
    assert.is_true(encrypted.write(bufnr))
    assert.same(
      { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' },
      vim.fn.readfile(file)
    )
  end)

  it('gives up at once when sops rejects what it got back', function()
    -- sops asks the editor again when it cannot parse the result
    tool('sops', {
      'case "$1" in',
      '  decrypt) sed -n "s/^plain: //p" "$2";;',
      '  edit) t=$(mktemp); $SOPS_EDITOR "$t" || exit 9',
      '        $SOPS_EDITOR "$t" || { rm -f "$t"; exit 128; }',
      '        exit 0;;',
      'esac',
    })
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr = open(file)
    local started = vim.uv.hrtime()
    assert.is_false(encrypted.write(bufnr))
    assert.is_true((vim.uv.hrtime() - started) / 1e6 < 5000)
    assert.is_truthy(notes[#notes]:find('Not written', 1, true))
    -- Nothing of the copy and its editor left in the temporary directory
    local leftovers =
      vim.fn.glob(vim.fs.dirname(vim.fn.tempname()) .. '/*', false, true)
    for _, left in ipairs(leftovers) do
      assert.is_nil(left:find('%.editor$'), left)
      assert.is_nil(left:find('%.used$'), left)
    end
  end)

  it('encrypts once per write, however often the file was opened', function()
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr = open(file)
    vim.cmd('bdelete')
    vim.cmd.edit(file)
    decrypt(bufnr)
    vim.fn.writefile({}, log)
    vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'a: 2' })
    vim.cmd('write')
    local edits = vim.tbl_filter(
      function(line) return line:find('^sops edit') ~= nil end,
      calls()
    )
    assert.equals(1, #edits)
  end)

  it('refuses to write a decrypted buffer to another file', function()
    local file = dir .. '/values.yaml'
    local original = { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' }
    h.write(file, original)
    local bufnr = open(file)
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'a: 2' })
    vim.cmd('silent! write ' .. dir .. '/copy.yaml')
    assert.same(original, vim.fn.readfile(file))
    assert.is_true(vim.bo[bufnr].modified)
    assert.is_truthy(notes[#notes]:find('Not written', 1, true))
  end)

  it('keeps the command history out of the shada file', function()
    local saved = vim.o.shada
    vim.o.shada = "!,'100,<50,s10,h"
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    open(file)
    vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'dy_encrypted_shada' })
    local shada = vim.o.shada
    vim.o.shada = saved
    assert.equals("!,'100,s10,h,<0,/0,@0,:0", shada)
  end)

  it('keeps the clear text out of the system clipboard', function()
    local saved = vim.o.clipboard
    vim.o.clipboard = 'unnamedplus'
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    open(file)
    assert.equals('', vim.o.clipboard)
    vim.cmd.enew()
    assert.equals('unnamedplus', vim.o.clipboard)
    vim.o.clipboard = saved
  end)

  it('gives the clipboard back after the buffer was guarded again', function()
    local saved = vim.o.clipboard
    vim.o.clipboard = 'unnamedplus'
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr = open(file)
    -- What `:e!` does, with the clipboard already cleared
    encrypted.guard(bufnr)
    vim.cmd.enew()
    assert.equals('unnamedplus', vim.o.clipboard)
    vim.o.clipboard = saved
  end)

  it(
    'takes over the clipboard config.lazy holds back until VeryLazy',
    function()
      local saved = vim.o.clipboard
      local options = { clipboard = 'unnamedplus' }
      local restore =
        h.stub(package.loaded, 'util.plugin', { options = options })
      vim.o.clipboard = ''
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      open(file)
      -- Nothing left for `VeryLazy` to put back over the clear text
      assert.is_nil(options.clipboard)
      assert.equals('', vim.o.clipboard)
      vim.cmd.enew()
      assert.equals('unnamedplus', vim.o.clipboard)
      restore()
      vim.o.clipboard = saved
    end
  )

  it('maps the recipients and rotations on a sops file only', function()
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr = open(file)
    for _, lhs in ipairs({
      '<localleader>K',
      '<localleader>U',
      '<localleader>N',
    }) do
      local map = vim.fn.maparg(lhs, 'n', false, true)
      assert.equals(bufnr, map.buffer == 1 and bufnr or -1)
    end

    local vault = dir .. '/vault.yml'
    h.write(vault, { '$ANSIBLE_VAULT;1.2;AES256', 'enc:db_password: x' })
    open(vault)
    assert.same({}, vim.fn.maparg('<localleader>K', 'n', false, true))
  end)

  it('keeps the vault id of an Ansible Vault', function()
    local file = dir .. '/vault.yml'
    h.write(file, { '$ANSIBLE_VAULT;1.2;AES256;prod', 'enc:db_password: x' })
    local bufnr = open(file)
    assert.same(
      { 'db_password: x' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    vim.cmd('write')
    local encrypt = calls()[2]
    assert.is_truthy(
      encrypt:find('ansible-vault encrypt --output ' .. file, 1, true)
    )
    assert.is_truthy(encrypt:find('--encrypt-vault-id prod', 1, true))
    assert.equals('enc:db_password: x', vim.fn.readfile(file)[2])
  end)

  it('opens a chezmoi source file through chezmoi', function()
    local file = dir .. '/encrypted_private_dot_netrc.age'
    h.write(file, { 'age:machine example.com', 'age:password hunter2' })
    local bufnr = open(file)
    assert.same(
      { 'machine example.com', 'password hunter2' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    assert.equals(
      'decrypted with chezmoi',
      require('util.sensitive').marked(bufnr)
    )
    vim.api.nvim_buf_set_lines(bufnr, 1, 2, false, { 'password changed' })
    vim.cmd('write')
    assert.same(
      { 'age:machine example.com', 'age:password changed' },
      vim.fn.readfile(file)
    )
    assert.is_truthy(
      calls()[2]:find('^chezmoi encrypt %-%-output ' .. vim.pesc(file))
    )
  end)

  it(
    'decrypts off the main loop, the ciphertext read-only meanwhile',
    function()
      tool('sops', { 'sleep 1', 'sed -n "s/^plain: //p" "$2"' })
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      vim.cmd.edit(file)
      local bufnr = vim.api.nvim_get_current_buf()
      local decrypted
      local started = vim.uv.hrtime()
      encrypted.open(bufnr, function(ok) decrypted = ok end)
      assert.is_true((vim.uv.hrtime() - started) / 1e6 < 500)
      assert.is_nil(decrypted)
      assert.is_false(vim.bo[bufnr].modifiable)
      assert.is_true(vim.wait(5000, function() return decrypted ~= nil end, 10))
      assert.is_true(decrypted)
      assert.is_true(vim.bo[bufnr].modifiable)
      assert.same({ 'a: 1' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    end
  )

  it('leaves a buffer read again meanwhile as it now is', function()
    tool('sops', { 'sleep 0.3', 'sed -n "s/^plain: //p" "$2"' })
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    vim.cmd.edit(file)
    local bufnr = vim.api.nvim_get_current_buf()
    local decrypted
    encrypted.open(bufnr, function(ok) decrypted = ok end)
    -- What reading the file again does once it is no longer encrypted
    h.write(file, { 'plain now' })
    vim.bo[bufnr].modifiable = true
    vim.cmd('edit!')
    assert.is_true(vim.wait(5000, function() return decrypted ~= nil end, 10))
    assert.is_false(decrypted)
    assert.same(
      { 'plain now' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    assert.are_not.equal('acwrite', vim.bo[bufnr].buftype)
  end)

  it('leaves the ciphertext when the clear text was cut', function()
    local restore = h.stub(require('util.system'), 'MAX_BYTES', 2)
    local file = dir .. '/values.yaml'
    h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr, decrypted = open(file)
    restore()
    assert.is_false(decrypted)
    assert.equals(
      'x: ENC[AES256_GCM,data:x]',
      vim.api.nvim_buf_get_lines(bufnr, 1, 2, false)[1]
    )
    assert.are_not.equal('acwrite', vim.bo[bufnr].buftype)
    assert.is_true(vim.bo[bufnr].modifiable)
  end)

  it('leaves the ciphertext as it is when decryption fails', function()
    tool('sops', { 'echo "no key could decrypt the data" >&2', 'exit 128' })
    local file = dir .. '/values.yaml'
    h.write(file, { 'a: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr, decrypted = open(file)
    assert.is_false(decrypted)
    assert.same(
      { 'a: ENC[AES256_GCM,data:x]', 'sops:' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    assert.are_not.equal('acwrite', vim.bo[bufnr].buftype)
    assert.is_truthy(
      notes[#notes]:find('no key could decrypt the data', 1, true)
    )
  end)

  it('leaves the ciphertext when sops hangs past the deadline', function()
    -- A child holding the output open, as a `gpg-agent` started by sops does
    tool('sops', { 'sleep 5 &', 'wait' })
    local restore = h.stub(encrypted, 'TIMEOUT', 200)
    local file = dir .. '/values.yaml'
    h.write(file, { 'a: ENC[AES256_GCM,data:x]', 'sops:' })
    local bufnr, decrypted = open(file)
    restore()
    assert.is_false(decrypted)
    assert.same(
      { 'a: ENC[AES256_GCM,data:x]', 'sops:' },
      vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    )
    assert.is_truthy(notes[#notes]:find('timed out', 1, true))
  end)

  it('never writes the clear text when encryption fails', function()
    local file = dir .. '/encrypted_dot_token.age'
    h.write(file, { 'age:secret' })
    local bufnr = open(file)
    tool('chezmoi', { 'echo "no recipients" >&2', 'exit 1' })
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'other' })
    vim.cmd('silent! write')
    assert.same({ 'age:secret' }, vim.fn.readfile(file))
    assert.is_true(vim.bo[bufnr].modified)
    assert.is_truthy(notes[#notes]:find('Not written: no recipients', 1, true))
  end)

  it('keeps a missing final newline of the clear text', function()
    tool('chezmoi', {
      'case "$1" in',
      "  decrypt) printf 'token';;",
      '  encrypt) cp "$4" "$3";;',
      'esac',
    })
    local file = dir .. '/encrypted_dot_api.asc'
    h.write(file, { 'ciphertext' })
    local bufnr = open(file)
    assert.same({ 'token' }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'other' })
    vim.cmd('write')
    assert.same({ 'other' }, vim.fn.readfile(file, 'b'))
  end)

  it('leaves an ordinary file alone', function()
    local file = dir .. '/plain.yaml'
    h.write(file, { 'a: 1' })
    local _, decrypted = open(file)
    assert.is_false(decrypted)
    assert.equals(0, vim.fn.filereadable(log))
  end)

  describe('when a tool is gone or fails', function()
    it('says why Ansible Vault did not write', function()
      local vault = dir .. '/vault.yml'
      h.write(vault, { '$ANSIBLE_VAULT;1.1;AES256', 'enc:secret' })
      local bufnr = open(vault)
      tool('ansible-vault', {
        'case "$1" in',
        '  decrypt) sed 1d "$4" | sed "s/^enc://";;',
        '  encrypt) echo "no password" >&2; exit 1;;',
        'esac',
      })
      assert.is_false(encrypted.write(bufnr))
      assert.equals(
        'Not written: no password'
          .. '\nAnsible Vault cannot ask for a password here: set'
          .. ' ANSIBLE_VAULT_PASSWORD_FILE, or vault_password_file in ansible.cfg',
        notes[#notes]
      )
    end)

    it('writes nothing once the tool is not installed', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      local bufnr = open(file)
      local restore = h.stub(vim.fn, 'executable', function() return 0 end)
      local written = encrypted.write(bufnr)
      restore()
      assert.is_false(written)
      assert.equals('sops is not installed: not written', notes[#notes])
    end)

    it('says when the encryption could not start', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      local bufnr = open(file)
      local restore = h.stub(
        require('util.system'),
        'sync',
        function() error('spawn failed', 0) end
      )
      local written = encrypted.write(bufnr)
      restore()
      assert.is_false(written)
      assert.equals('spawn failed', notes[#notes])
    end)

    it('leaves the ciphertext when the tool is not installed', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      local restore = h.stub(vim.fn, 'executable', function() return 0 end)
      local bufnr, decrypted = open(file)
      restore()
      assert.is_false(decrypted)
      assert.equals('sops is not installed: left encrypted', notes[#notes])
      assert.equals(
        'plain: a: 1',
        vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
      )
      assert.is_true(require('util.sensitive').is_sensitive(bufnr))
    end)

    it('leaves a buffer too long to be a secret alone', function()
      local lines = {}
      for i = 1, 20001 do
        lines[i] = 'x: ENC[AES256_GCM,data:x]'
      end
      local bufnr = h.buffer({ name = dir .. '/big.yaml', lines = lines })
      assert.is_false(decrypt(bufnr))
      assert.equals(0, vim.fn.filereadable(log))
    end)

    it('lists no recipients when the metadata names none', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      open(file)
      encrypted.keys()
      assert.equals(
        'No recipient found in the metadata of ' .. file,
        notes[#notes]
      )
    end)

    it('rotates nothing without sops, and says when sops failed', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      open(file)
      local restore = h.stub(vim.fn, 'confirm', function() return 1 end)
      tool('sops', {
        'case "$1" in',
        '  decrypt) sed -n "s/^plain: //p" "$2";;',
        '  updatekeys) echo "no key" >&2; exit 1;;',
        'esac',
      })
      local before = #notes
      encrypted.rotate()
      assert.is_true(vim.wait(5000, function() return #notes > before end, 10))
      assert.equals('sops failed: no key', notes[#notes])

      local restore_exe = h.stub(vim.fn, 'executable', function() return 0 end)
      encrypted.rotate()
      restore_exe()
      restore()
      assert.equals('sops is not installed', notes[#notes])
    end)
  end)

  describe('keys', function()
    it('reads the recipients off the metadata only', function()
      local yaml = {
        'fp: ENC[AES256_GCM,data:x]',
        'arn: plain-data-not-metadata',
        'sops:',
        '  kms:',
        '    - arn: arn:aws:kms:eu-west-1:1:key/abc',
        '  age:',
        '    - recipient: age1aaa',
        '      enc: |',
        '    - recipient: age1bbb',
        '  pgp:',
        '    - fp: ABCDEF',
      }
      assert.same({
        { kind = 'kms', id = 'arn:aws:kms:eu-west-1:1:key/abc' },
        { kind = 'age', id = 'age1aaa' },
        { kind = 'age', id = 'age1bbb' },
        { kind = 'pgp', id = 'ABCDEF' },
      }, encrypted.recipients(yaml))
      assert.same(
        { { kind = 'age', id = 'age1ccc' } },
        encrypted.recipients({
          '{',
          '  "a": "ENC[AES256_GCM,data:x]",',
          '  "sops": {',
          '    "age": [ { "recipient": "age1ccc", "enc": "x" } ]',
        })
      )
      assert.same(
        { { kind = 'age', id = 'age1ddd' } },
        encrypted.recipients({
          'A=ENC[AES256_GCM,data:x]',
          'sops_age__list_0__map_recipient=age1ddd',
        })
      )
    end)

    it('lists them for a decrypted sops file, and nothing else', function()
      local file = dir .. '/values.yaml'
      h.write(file, {
        'plain: a: 1',
        'x: ENC[AES256_GCM,data:x]',
        'sops:',
        '  age:',
        '    - recipient: age1zzz',
      })
      open(file)
      encrypted.keys()
      local text =
        table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
      assert.is_truthy(text:find('- age      age1zzz', 1, true))

      vim.cmd.enew()
      encrypted.keys()
      assert.equals('Recipients are read from a sops file', notes[#notes])
    end)

    it('rotates through sops once agreed, and opens the file again', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      local bufnr = open(file)
      tool('sops', {
        'case "$1" in',
        '  decrypt) sed -n "s/^plain: //p" "$2";;',
        '  updatekeys|rotate) printf "plain: rotated\\nx: ENC[AES256_GCM,data:y]\\nsops:\\n" > "$3";;',
        'esac',
      })
      local restore = h.stub(vim.fn, 'confirm', function() return 2 end)
      encrypted.rotate('rotate')
      restore()
      assert.is_falsy(
        vim.tbl_contains(calls(), 'sops rotate --in-place ' .. file)
      )

      restore = h.stub(vim.fn, 'confirm', function() return 1 end)
      local read = 0
      vim.api.nvim_create_autocmd('BufReadPost', {
        buffer = bufnr,
        callback = function() read = read + 1 end,
      })
      local before = #notes
      encrypted.rotate('rotate')
      restore()
      -- sops runs off the main loop
      assert.equals(before, #notes)
      assert.is_true(vim.wait(5000, function() return #notes > before end, 10))
      assert.is_truthy(
        vim.tbl_contains(calls(), 'sops rotate --in-place ' .. file)
      )
      -- Read again, and decrypted off the main loop in turn
      assert.is_true(
        vim.wait(
          5000,
          function()
            return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)[1]
              == 'rotated'
          end,
          10
        )
      )
      assert.same(
        { 'rotated' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
      assert.equals('New data key', notes[#notes])
      -- Decrypted in place: the buffer was never read again from disk
      assert.equals(0, read)
      assert.equals('acwrite', vim.bo[bufnr].buftype)
    end)

    it('keeps edits made while sops ran', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      local bufnr = open(file)
      tool('sops', {
        'case "$1" in',
        '  decrypt) sed -n "s/^plain: //p" "$2";;',
        '  updatekeys) sleep 0.3;;',
        'esac',
      })
      local restore = h.stub(vim.fn, 'confirm', function() return 1 end)
      local before = #notes
      encrypted.rotate()
      restore()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'typed meanwhile' })
      assert.is_true(vim.wait(5000, function() return #notes > before end, 10))
      assert.same(
        { 'typed meanwhile' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
      assert.is_truthy(notes[#notes]:find('was not read again', 1, true))
    end)

    it('rotates nothing modified, nor any other kind', function()
      local file = dir .. '/values.yaml'
      h.write(file, { 'plain: a: 1', 'x: ENC[AES256_GCM,data:x]', 'sops:' })
      local bufnr = open(file)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'changed' })
      encrypted.rotate()
      assert.is_truthy(notes[#notes]:find('Write the file first', 1, true))
      encrypted.rotate('nope')
      assert.equals('Unknown rotation: nope', notes[#notes])

      local vault = dir .. '/vault.yml'
      h.write(vault, { '$ANSIBLE_VAULT;1.1;AES256', 'enc:secret' })
      open(vault)
      encrypted.rotate()
      assert.is_truthy(notes[#notes]:find('Only a sops file', 1, true))
    end)
  end)

  describe('diff', function()
    local repo

    --- `git` in the scratch repository
    local function git(...)
      local result = vim
        .system(
          vim.list_extend(
            { 'git', '-c', 'user.name=t', '-c', 'user.email=t@t' },
            { ... }
          ),
          { cwd = repo }
        )
        :wait()
      assert.equals(0, result.code, result.stderr)
    end

    before_each(function()
      repo = dir .. '/repo'
      vim.fn.mkdir(repo, 'p')
      git('init', '-q')
      h.write(repo .. '/values.yaml', {
        'plain: password: old',
        'x: ENC[AES256_GCM,data:x]',
        'sops:',
      })
      git('add', 'values.yaml')
      git('commit', '-q', '-m', 'first')
      h.write(repo .. '/values.yaml', {
        'plain: password: new',
        'x: ENC[AES256_GCM,data:x]',
        'sops:',
      })
    end)

    it('diffs the clear text with the one at HEAD, held back', function()
      local bufnr = open(repo .. '/values.yaml')
      assert.same(
        { 'password: new' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )

      encrypted.command({ fargs = {} })
      -- git and the decryption run off the main loop
      assert.equals(1, #vim.api.nvim_tabpage_list_wins(0))
      assert.is_true(
        vim.wait(
          5000,
          function() return #vim.api.nvim_tabpage_list_wins(0) == 2 end,
          10
        )
      )
      -- The cursor is back on the buffer being edited, the old text beside it
      assert.equals(bufnr, vim.api.nvim_get_current_buf(), vim.inspect(notes))
      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.equals(2, #wins)
      local scratch = vim.api.nvim_win_get_buf(wins[1])
      assert.same(
        { 'password: old' },
        vim.api.nvim_buf_get_lines(scratch, 0, -1, false)
      )
      assert.is_truthy(require('util.sensitive').marked(scratch))
      assert.equals('nofile', vim.bo[scratch].buftype)
      assert.is_false(vim.bo[scratch].swapfile)
      assert.is_false(vim.bo[scratch].modifiable)
      assert.is_true(vim.wo[vim.fn.bufwinid(scratch)].diff)
      assert.is_true(vim.wo[vim.fn.bufwinid(bufnr)].diff)

      -- The copy sops read is gone, with the directory it was put in
      local decrypted = vim.tbl_filter(
        function(line) return line:match('^sops decrypt .*/values%.yaml$') end,
        calls()
      )
      local copy = decrypted[#decrypted]:match('^sops decrypt (.*)$')
      assert.are_not.equal(repo .. '/values.yaml', copy)
      assert.equals(0, vim.fn.filereadable(copy))
      assert.equals(0, vim.fn.isdirectory(vim.fs.dirname(copy)))
    end)

    it('leaves diff mode once the old text is closed', function()
      local bufnr = open(repo .. '/values.yaml')
      encrypted.diff(bufnr)
      assert.is_true(
        vim.wait(
          5000,
          function() return #vim.api.nvim_tabpage_list_wins(0) == 2 end,
          10
        )
      )
      local wins = vim.api.nvim_tabpage_list_wins(0)
      local scratch_win = wins[1]
      assert.are_not.equal(bufnr, vim.api.nvim_win_get_buf(scratch_win))
      vim.api.nvim_win_close(scratch_win, true)
      assert.is_true(
        vim.wait(
          1000,
          function() return not vim.wo[vim.fn.bufwinid(bufnr)].diff end,
          10
        )
      )
    end)

    it(
      'takes the buffer out of diff mode once the old text is wiped',
      function()
        local bufnr = open(repo .. '/values.yaml')
        encrypted.open_diff(bufnr, 'HEAD', 'sops', { 'password: old' })
        local win = vim.fn.bufwinid(bufnr)
        local scratch
        for _, other in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
          if other ~= win then scratch = vim.api.nvim_win_get_buf(other) end
        end
        assert.are_not.equal(bufnr, scratch)
        assert.is_true(vim.wo[win].diff)
        vim.cmd('bwipeout! ' .. scratch)
        -- The window of the buffer leaves diff mode on the next turn of the
        -- loop, with the window still there
        vim.wait(500)
        assert.is_true(vim.api.nvim_win_is_valid(win))
        assert.is_false(vim.wo[win].diff)
      end
    )

    it('says when the file is not in git at the revision', function()
      h.write(repo .. '/new.yaml', {
        'plain: a',
        'x: ENC[AES256_GCM,data:x]',
        'sops:',
      })
      local bufnr = open(repo .. '/new.yaml')
      local before = #notes
      encrypted.diff(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > before end, 10))
      assert.equals(bufnr, vim.api.nvim_get_current_buf())
      assert.is_truthy(
        notes[#notes]:find('new.yaml is not in git at HEAD', 1, true)
      )
    end)

    it('fails on a clear text at the revision that was cut', function()
      local bufnr = open(repo .. '/values.yaml')
      tool('sops', { "printf '%0500d' 0" })
      local restore = h.stub(require('util.system'), 'MAX_BYTES', 100)
      local lines, err
      encrypted.clear_at(bufnr, 'HEAD', function(l, e)
        lines, err = l, e or ''
      end)
      assert.is_true(vim.wait(5000, function() return err ~= nil end, 10))
      restore()
      assert.is_nil(lines)
      assert.is_truthy(err:find('could not decrypt it', 1, true))
    end)

    it('fails on a ciphertext at the revision too large to read', function()
      local bufnr = open(repo .. '/values.yaml')
      local restore = h.stub(require('util.system'), 'MAX_BYTES', 10)
      local lines, err
      encrypted.clear_at(bufnr, 'HEAD', function(l, e)
        lines, err = l, e or ''
      end)
      assert.is_true(vim.wait(5000, function() return err ~= nil end, 10))
      restore()
      assert.is_nil(lines)
      assert.equals('values.yaml at HEAD is too large to read', err)
    end)

    it('fails when no private copy can be written', function()
      local bufnr = open(repo .. '/values.yaml')
      local fs_open = vim.uv.fs_open
      local restore = h.stub(vim.uv, 'fs_open', function(path, ...)
        if vim.fs.basename(path) == 'values.yaml' then return nil end
        return fs_open(path, ...)
      end)
      local lines, err
      encrypted.clear_at(bufnr, 'HEAD', function(l, e)
        lines, err = l, e or ''
      end)
      assert.is_true(vim.wait(5000, function() return err ~= nil end, 10))
      restore()
      assert.is_nil(lines)
      assert.equals('could not write a private copy', err)
    end)

    it('refuses a buffer that was not decrypted', function()
      vim.cmd.edit(repo .. '/plain.txt')
      encrypted.diff(0)
      assert.equals('This buffer is not a decrypted file', notes[#notes])
    end)

    it('maps <localleader>D on a decrypted buffer', function()
      local bufnr = open(repo .. '/values.yaml')
      local map = vim.fn.maparg('<localleader>D', 'n', false, true)
      assert.equals(bufnr, map.buffer == 1 and bufnr or -1)
    end)
  end)
end)
