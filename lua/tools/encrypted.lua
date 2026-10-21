--- Encrypted files, edited in the clear and written back encrypted
---
--- A SOPS file, an Ansible Vault or an `encrypted_` file of a chezmoi source
--- opens as what it holds rather than as ciphertext, and `:w` encrypts it
--- again. The clear text never reaches the file it came from: SOPS writes
--- through `sops edit`, which keeps the data key and the recipients of the
--- file as they were, Ansible Vault through `ansible-vault encrypt --output`,
--- and chezmoi through `chezmoi encrypt --output`, to the recipients of its
--- configuration. The copy each needs on its way is a file of Neovim's own
--- private temporary directory, removed straight after.
---
--- The buffer is marked sensitive before the clear text goes in, so no AI
--- integration is handed it, and it keeps no swap or undo file. Its undo
--- history starts at the clear text: there is no undoing back to ciphertext
--- and writing that out encrypted twice.
local M = {}

local sensitive = require('util.sensitive')

--- Milliseconds a decryption or an encryption may take: a KMS or a hardware
--- key can be slow, but not forever
M.TIMEOUT = 60 * 1000

--- Lines read to tell what a buffer is, beyond which it is left alone
local MAX_LINES = 20000

---@alias DyEncryptedKind 'sops'|'ansible'|'chezmoi'

--- What each kind is called, and the program that handles it
local TOOLS = {
  sops = { name = 'sops', bin = 'sops' },
  ansible = { name = 'Ansible Vault', bin = 'ansible-vault' },
  chezmoi = { name = 'chezmoi', bin = 'chezmoi' },
}

--- Whether `file` is an encrypted file of a chezmoi source directory
---
--- chezmoi names them itself: `encrypted_` in front, `.age` behind for age,
--- `.asc` for gpg. They are opened through chezmoi, whose configuration
--- holds the identity and the recipients.
---@param file string
---@return boolean
function M.is_chezmoi(file)
  local name = vim.fs.basename(file or '')
  return name:match('^encrypted_.+%.age$') ~= nil
    or name:match('^encrypted_.+%.asc$') ~= nil
end

--- What encrypts the file `lines` were read from, if anything
---
--- SOPS leaves its values as `ENC[AES256_GCM,...]` and its metadata under a
--- `sops` key -- at the end of a YAML file, inside a JSON one, as `sops_`
--- lines in a dotenv file. Ansible Vault starts the file with its header,
--- and chezmoi is told by the name of its source file.
---@param lines string[]
---@param file? string
---@return DyEncryptedKind?
function M.kind(lines, file)
  if file and M.is_chezmoi(file) then return 'chezmoi' end
  if lines[1] and lines[1]:match('^%$ANSIBLE_VAULT;%d+%.%d+;') then
    return 'ansible'
  end
  local value, metadata = false, false
  for _, line in ipairs(lines) do
    value = value or line:find('ENC[AES256_GCM,', 1, true) ~= nil
    metadata = metadata
      or line:match('^sops:') ~= nil
      or line:match('^%s*"sops"%s*:') ~= nil
      or line:match('^sops_[%w_]+=') ~= nil
      or line:match('^%[sops%]') ~= nil
    if value and metadata then return 'sops' end
  end
  return nil
end

--- The vault id of an Ansible Vault 1.2 header, which encrypting again keeps
---@param header string
---@return string?
function M.vault_id(header)
  return header:match('^%$ANSIBLE_VAULT;1%.2;[^;]+;(.+)$')
end

--- The command that prints the clear text of `file`
---@param kind DyEncryptedKind
---@param file string
---@return string[]
function M.decrypt_command(kind, file)
  if kind == 'sops' then return { 'sops', 'decrypt', file } end
  if kind == 'chezmoi' then return { 'chezmoi', 'decrypt', file } end
  return { 'ansible-vault', 'decrypt', '--output', '-', file }
end

local notify = require('util.notify').titled('Encrypted file')

--- What to say when the tool of `kind` failed
---@param kind DyEncryptedKind
---@param result vim.SystemCompleted
---@return string
local function failure(kind, result)
  local err = vim.trim(result.stderr or '')
  if result.timed_out then
    err = ('timed out after %d s'):format(M.TIMEOUT / 1000)
  elseif result.cut then
    err = 'more output than can be read'
  elseif err == '' then
    err = ('exit %d'):format(result.code)
  end
  if kind == 'ansible' then
    err = err
      .. '\nAnsible Vault cannot ask for a password here: set'
      .. ' ANSIBLE_VAULT_PASSWORD_FILE, or vault_password_file in ansible.cfg'
  end
  return err
end

--- A file only this user can read, holding `lines`, in Neovim's private
--- temporary directory
---@param lines string[]
---@param noeol? boolean Leave out the newline after the last line
---@return string
local function private_copy(lines, noeol)
  local path = vim.fn.tempname()
  vim.fn.writefile({}, path)
  vim.fn.setfperm(path, 'rw-------')
  vim.fn.writefile(lines, path, noeol and 'b' or '')
  return path
end

--- The editor `sops edit` runs to put the buffer in place: it copies `copy`
--- over the file sops hands it, once. sops asks the editor again when it
--- cannot parse what it got back, waiting for a key in between -- which,
--- with no terminal, never comes, and sops loops until it is killed and
--- leaves its own clear copy behind. A second call fails instead, and sops
--- gives up and cleans up after itself.
---@param copy string
---@return string script
---@return string marker
local function sops_editor(copy)
  local script, marker = copy .. '.editor', copy .. '.used'
  vim.fn.writefile({
    '#!/bin/sh',
    ('[ -e %s ] && exit 1'):format(vim.fn.shellescape(marker)),
    (': > %s'):format(vim.fn.shellescape(marker)),
    ('exec cp %s "$1"'):format(vim.fn.shellescape(copy)),
  }, script)
  vim.fn.setfperm(script, 'rwx------')
  return script, marker
end

--- Encrypt the clear text of `bufnr` back into its file
---@param bufnr integer
---@return boolean written
function M.write(bufnr)
  local kind = vim.b[bufnr].dy_encrypted
  -- A handler left from an earlier opening of a buffer no longer decrypted
  if not TOOLS[kind] then return false end
  local file = vim.api.nvim_buf_get_name(bufnr)
  local tool = TOOLS[kind].bin
  if vim.fn.executable(tool) ~= 1 then
    notify(tool .. ' is not installed: not written', vim.log.levels.ERROR)
    return false
  end

  local copy = private_copy(
    vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    not vim.bo[bufnr].endofline and not vim.bo[bufnr].fixendofline
  )
  local command, env
  local extra = {}
  if kind == 'sops' then
    -- `sops edit` decrypts into a file of its own, hands it to the editor
    -- and encrypts what the editor left there with the key it already had.
    -- The editor here only copies the buffer over that file.
    command = { 'sops', 'edit', file }
    local script, marker = sops_editor(copy)
    extra = { script, marker }
    env = { SOPS_EDITOR = script, EDITOR = script }
  elseif kind == 'chezmoi' then
    -- To the recipients of chezmoi's configuration, armoured or not as
    -- that configuration says
    command = { 'chezmoi', 'encrypt', '--output', file, copy }
  else
    command = { 'ansible-vault', 'encrypt', '--output', file, copy }
    local id = vim.b[bufnr].dy_vault_id
    if id then vim.list_extend(command, { '--encrypt-vault-id', id }) end
  end

  local ok, result = pcall(require('util.system').sync, command, {
    text = true,
    env = env,
    timeout = M.TIMEOUT,
    -- No controlling terminal: a password prompt on /dev/tty would
    -- fight the TUI for keys while the editor waits
    detach = true,
  })
  vim.fn.delete(copy)
  for _, path in ipairs(extra) do
    vim.fn.delete(path)
  end
  if not ok then
    notify(tostring(result), vim.log.levels.ERROR)
    return false
  end
  -- `sops edit` exits 200 when the file came back unchanged
  if result.code ~= 0 and not (kind == 'sops' and result.code == 200) then
    notify('Not written: ' .. failure(kind, result), vim.log.levels.ERROR)
    return false
  end
  vim.bo[bufnr].modified = false
  notify(('Written, encrypted with %s'):format(TOOLS[kind].name))
  return true
end

--- Run `command` off the main loop, never raising, and hand `on_done` what
--- it did; nil when it could not start
---@param command string[]
---@param opts table `vim.system` options
---@param on_done fun(result: vim.SystemCompleted?)
local function run(command, opts, on_done)
  require('util.system').run(
    command,
    vim.tbl_extend('force', { timeout = M.TIMEOUT, detach = true }, opts),
    function(result) on_done(not result.missing and result or nil) end
  )
end

--- The decryption each buffer waits on, so an older one finishing late
--- leaves the buffer to the newer
---@type table<integer, integer>
local decrypting = {}
local next_decryption = 0

--- Decrypt the file of `bufnr` off the main loop and put its clear text in
---
--- The buffer stays read-only until then. `unchanged` is asked once the
--- clear text is back: a buffer that moved on meanwhile is left as it is.
---@param bufnr integer
---@param kind DyEncryptedKind
---@param header? string The first line of the ciphertext
---@param unchanged fun(): boolean
---@param on_done fun(decrypted: boolean)
local function decrypt_into(bufnr, kind, header, unchanged, on_done)
  local command = M.decrypt_command(kind, vim.api.nvim_buf_get_name(bufnr))
  next_decryption = next_decryption + 1
  local id = next_decryption
  decrypting[bufnr] = id
  vim.bo[bufnr].modifiable = false
  run(command, { text = true }, function(result)
    if decrypting[bufnr] ~= id then return on_done(false) end
    decrypting[bufnr] = nil
    if not vim.api.nvim_buf_is_valid(bufnr) then return on_done(false) end
    vim.bo[bufnr].modifiable = true
    if not unchanged() then return on_done(false) end
    -- A cut clear text, written back, would encrypt only part of the file
    if not result or result.code ~= 0 or result.cut then
      notify(
        'Left encrypted: '
          .. (
            result and failure(kind, result) or (command[1] .. ' did not run')
          ),
        vim.log.levels.ERROR
      )
      return on_done(false)
    end

    local stdout = result.stdout or ''
    local clear = vim.split(stdout:gsub('\n$', ''), '\n', { plain = true })
    -- No undoing back to the ciphertext
    local undolevels = vim.bo[bufnr].undolevels
    vim.bo[bufnr].undolevels = -1
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, clear)
    vim.bo[bufnr].undolevels = undolevels
    -- A key or a token without a final newline is written back without one
    local eol = stdout:sub(-1) == '\n'
    vim.bo[bufnr].endofline = eol
    if not eol then vim.bo[bufnr].fixendofline = false end
    vim.bo[bufnr].modified = false

    vim.b[bufnr].dy_encrypted = kind
    vim.b[bufnr].dy_vault_id = kind == 'ansible'
        and header
        and M.vault_id(header)
      or nil
    vim.bo[bufnr].buftype = 'acwrite'
    M.guard(bufnr)
    on_done(true)
  end)
end

--- A directory `:DyReview` checks a pull request out into
local REVIEW_WORKTREE = '/%.worktrees/dyreview%-[^/]+/'

--- Why the file of `bufnr` is not opened in the clear, if it is not
---
--- A pull request's file chooses, through its own metadata, where the
--- reviewer's credentials go: a sops `hc_vault` address, a KMS key, an
--- Ansible vault id. A held buffer and every file of a review worktree stay
--- encrypted, the latter even once its code is trusted: trusting the code
--- is not consent to spend the reviewer's keys on its files.
---@param bufnr integer
---@param file string
---@return string?
function M.untrusted(bufnr, file)
  if require('util.untrusted').held(bufnr) then
    return 'it lies in a directory not trusted yet'
  end
  local real = vim.uv.fs_realpath(file) or file
  for _, path in ipairs({ vim.fs.normalize(file), vim.fs.normalize(real) }) do
    if path:find(REVIEW_WORKTREE) then
      return 'it belongs to a pull request under review'
    end
  end
  return nil
end

--- Open the clear text of `bufnr`, if it holds an encrypted file
---
--- It is read on the main loop's behalf, not on it: a slow KMS, or an agent
--- waiting for a PIN it never gets, must not hold the editor for the whole
--- `M.TIMEOUT`. Until the clear text is in, the ciphertext stays read-only,
--- so nothing typed into it is lost when it is replaced.
---@param bufnr integer
---@param on_done? fun(decrypted: boolean)
function M.open(bufnr, on_done)
  on_done = on_done or function() end
  if vim.api.nvim_buf_line_count(bufnr) > MAX_LINES then
    return on_done(false)
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local kind = M.kind(lines, file)
  if not kind then return on_done(false) end
  local why = M.untrusted(bufnr, file)
  if why then
    notify(
      ('%s left encrypted: %s'):format(vim.fs.basename(file), why),
      vim.log.levels.WARN
    )
    return on_done(false)
  end

  -- Held back before anything of the clear text is in the buffer
  sensitive.mark(bufnr, ('decrypted with %s'):format(TOOLS[kind].name))
  pcall(function() require('util.ai_guard').detach_copilot(bufnr) end)
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false

  local bin = M.decrypt_command(kind, file)[1]
  if vim.fn.executable(bin) ~= 1 then
    notify(bin .. ' is not installed: left encrypted', vim.log.levels.WARN)
    return on_done(false)
  end

  -- Read again meanwhile, with something no longer this ciphertext. Not
  -- `changedtick`: reading a file moves it on after `BufReadPost`.
  decrypt_into(
    bufnr,
    kind,
    lines[1],
    function()
      return vim.deep_equal(
        lines,
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
    end,
    on_done
  )
end

--- Whether a buffer has held clear text this session, so the registers it
--- may have filled are kept out of the shada file
local decrypted_any = false

--- The `clipboard` value to restore on leaving each guarded buffer
---@type table<integer, string>
local saved_clipboard = {}

--- Write `bufnr` encrypted, and keep its clear text out of the system
--- clipboard while it is the current buffer
---
--- The autocmds live in a group of the buffer's own, cleared each time it
--- is opened: `:bdelete` forgets buffer variables but not buffer-local
--- autocmds, and a flag kept in one would let every reopening add another
--- handler, encrypting once per handler on each `:w`.
---@param bufnr integer
function M.guard(bufnr)
  local group =
    vim.api.nvim_create_augroup('dy_encrypted_' .. bufnr, { clear = true })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args)
      -- `:w {file}` fires this too: encrypting into the buffer's own file
      -- would replace it with edits meant for a copy
      local target = vim.fn.fnamemodify(args.file, ':p')
      if
        target ~= vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':p')
      then
        notify(
          'Not written: an encrypted file is only written to itself',
          vim.log.levels.ERROR
        )
        return
      end
      M.write(args.buf)
    end,
  })
  vim.keymap.set(
    'n',
    '<localleader>D',
    function() M.diff(bufnr) end,
    { buffer = bufnr, desc = 'Diff With HEAD (Encrypted)' }
  )
  -- Only sops keeps its recipients in the file, readable without a password
  if vim.b[bufnr].dy_encrypted == 'sops' then
    for lhs, map in pairs({
      ['<localleader>K'] = { M.keys, 'Recipients (sops)' },
      ['<localleader>U'] = {
        function() M.rotate('updatekeys') end,
        'Update Recipients (sops)',
      },
      ['<localleader>N'] = {
        function() M.rotate('rotate') end,
        'New Data Key (sops)',
      },
    }) do
      vim.keymap.set('n', lhs, map[1], { buffer = bufnr, desc = map[2] })
    end
  end
  M.hold(bufnr, group)
end

--- Keep the clear text of `bufnr` out of the system clipboard while it is the
--- current buffer, and out of the shada file once Neovim quits
---@param bufnr integer
---@param group integer The augroup of the buffer's autocmds
function M.hold(bufnr, group)
  -- `unnamedplus` would put every yank of a password into the system
  -- clipboard, and from there into a clipboard manager's history. The value
  -- to restore is kept per buffer, outside this call: `:e!` guards the buffer
  -- again while the clipboard is already cleared, and must not take that ''
  -- for the user's setting. Before `VeryLazy`, `config.lazy` holds the
  -- user's value back in `util.plugin`'s options and the option is empty:
  -- that value is taken over here, so it is put back on leaving this buffer
  -- rather than at `VeryLazy`, with the clear text still current.
  local function clear()
    local options = package.loaded['util.plugin']
      and package.loaded['util.plugin'].options
    local deferred = options and options.clipboard
    if deferred ~= nil then options.clipboard = nil end
    if saved_clipboard[bufnr] == nil then
      saved_clipboard[bufnr] = deferred or vim.o.clipboard
    end
    vim.o.clipboard = ''
  end
  vim.api.nvim_create_autocmd('BufEnter', {
    group = group,
    buffer = bufnr,
    callback = clear,
  })
  vim.api.nvim_create_autocmd({ 'BufLeave', 'BufWipeout' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      if saved_clipboard[bufnr] ~= nil then
        vim.o.clipboard = saved_clipboard[bufnr]
        saved_clipboard[bufnr] = nil
      end
    end,
  })
  if vim.api.nvim_get_current_buf() == bufnr then clear() end

  if not decrypted_any then
    decrypted_any = true
    -- Registers and the search and command histories are written to the
    -- shada file on quitting: after clear text was in a buffer, none is kept
    vim.api.nvim_create_autocmd('VimLeavePre', {
      group = vim.api.nvim_create_augroup('dy_encrypted_shada', {}),
      -- Neovim reads the first `<` item, so the default `<50` has to go
      -- rather than have `<0` appended after it
      callback = function()
        local items = vim.tbl_filter(
          function(item) return not item:match('^[<"/@:]') end,
          vim.split(vim.o.shada, ',', { plain = true, trimempty = true })
        )
        vim.list_extend(items, { '<0', '/0', '@0', ':0' })
        vim.o.shada = table.concat(items, ',')
      end,
    })
  end
end

--- Hand `on_done` the clear text of the file of `bufnr` as it was at `rev`
---
--- The blob goes to a directory of its own only this user can read, under
--- the name of the file -- sops tells the format from the extension -- and
--- both are removed as soon as it is decrypted. Nothing of the clear text
--- is written anywhere.
---@param bufnr integer
---@param rev string
---@param on_done fun(lines: string[]?, err: string?)
function M.clear_at(bufnr, rev, on_done)
  local kind = vim.b[bufnr].dy_encrypted
  local file = vim.api.nvim_buf_get_name(bufnr)
  local dir, name = vim.fs.dirname(file), vim.fs.basename(file)
  run(
    { 'git', 'show', ('%s:./%s'):format(rev, name) },
    { cwd = dir, text = false },
    function(blob)
      if blob and blob.cut then
        return on_done(nil, ('%s at %s is too large to read'):format(name, rev))
      end
      if not blob or blob.code ~= 0 then
        return on_done(
          nil,
          ('%s is not in git at %s%s'):format(
            name,
            rev,
            blob and blob.stderr ~= '' and (': ' .. vim.trim(blob.stderr)) or ''
          )
        )
      end
      local private = vim.fn.tempname()
      vim.fn.mkdir(private, 'p', tonumber('700', 8))
      local copy = vim.fs.joinpath(private, name)
      local fd = vim.uv.fs_open(copy, 'w', tonumber('600', 8))
      if not fd then
        vim.fn.delete(private, 'rf')
        return on_done(nil, 'could not write a private copy')
      end
      vim.uv.fs_write(fd, blob.stdout or '')
      vim.uv.fs_close(fd)
      run(M.decrypt_command(kind, copy), { text = true }, function(result)
        vim.fn.delete(private, 'rf')
        if not result or result.code ~= 0 or result.cut then
          return on_done(
            nil,
            'could not decrypt it: '
              .. (result and failure(kind, result) or 'failed')
          )
        end
        on_done(
          vim.split(
            (result.stdout or ''):gsub('\n$', ''),
            '\n',
            { plain = true }
          )
        )
      end)
    end
  )
end

--- Diff the clear text of `bufnr` with its clear text at `rev` (`HEAD`), in
--- a split that is held back like the buffer itself
---@param bufnr? integer
---@param rev? string
function M.diff(bufnr, rev)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  rev = rev or 'HEAD'
  local kind = vim.b[bufnr].dy_encrypted
  if not kind then
    return notify('This buffer is not a decrypted file', vim.log.levels.ERROR)
  end
  M.clear_at(bufnr, rev, function(lines, err)
    if not lines then return notify(err, vim.log.levels.ERROR) end
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    M.open_diff(bufnr, rev, kind, lines)
  end)
end

--- Open `lines`, the clear text at `rev`, beside `bufnr`, both in diff mode
---@param bufnr integer
---@param rev string
---@param kind DyEncryptedKind
---@param lines string[]
function M.open_diff(bufnr, rev, kind, lines)
  local win = vim.fn.bufwinid(bufnr)
  if win ~= -1 then vim.api.nvim_set_current_win(win) end
  vim.cmd('leftabove vnew')
  local scratch = vim.api.nvim_get_current_buf()
  -- Held back before the clear text goes in, as the buffer itself is
  sensitive.mark(
    scratch,
    ('decrypted with %s, at %s'):format(TOOLS[kind].name, rev)
  )
  vim.bo[scratch].buftype = 'nofile'
  vim.bo[scratch].bufhidden = 'wipe'
  vim.bo[scratch].swapfile = false
  vim.bo[scratch].undofile = false
  vim.api.nvim_buf_set_lines(scratch, 0, -1, false, lines)
  vim.bo[scratch].modifiable = false
  vim.bo[scratch].filetype = vim.bo[bufnr].filetype
  pcall(
    vim.api.nvim_buf_set_name,
    scratch,
    ('%s@%s'):format(vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)), rev)
  )
  local group =
    vim.api.nvim_create_augroup('dy_encrypted_' .. scratch, { clear = true })
  M.hold(scratch, group)
  -- Gone with the old text: the window of the buffer leaves diff mode too
  vim.api.nvim_create_autocmd('BufWipeout', {
    group = group,
    buffer = scratch,
    once = true,
    callback = function()
      vim.schedule(function()
        local original = vim.fn.bufwinid(bufnr)
        if original ~= -1 then
          vim.api.nvim_win_call(original, function() vim.cmd('diffoff') end)
        end
      end)
    end,
  })
  vim.keymap.set(
    'n',
    'q',
    '<cmd>close<cr>',
    { buffer = scratch, desc = 'Close', nowait = true }
  )
  vim.cmd('diffthis')
  vim.cmd('wincmd p')
  vim.cmd('diffthis')
end

--- `:DyEncryptedDiff [{rev}]`
---@param args { fargs: string[] }
function M.command(args) M.diff(0, args.fargs[1]) end

---@class DyEncryptedRecipient
---@field kind 'age'|'kms'|'pgp'|'gcp_kms'|'azure_kv'|'hc_vault'
---@field id string

--- What each key of the sops metadata names, in YAML, JSON, INI or dotenv:
--- `recipient: age1…`, `"arn": "arn:aws:kms…"`, `sops_pgp__list_0__map_fp=…`
local RECIPIENT_KEYS = {
  { pattern = 'recipient', kind = 'age' },
  { pattern = 'arn', kind = 'kms' },
  { pattern = 'fp', kind = 'pgp' },
  { pattern = 'resource_id', kind = 'gcp_kms' },
  { pattern = 'vault_url', kind = 'azure_kv' },
  { pattern = 'vaultUrl', kind = 'azure_kv' },
  { pattern = 'vault_address', kind = 'hc_vault' },
}

--- The recipients the sops metadata of an encrypted file names: public
--- keys and key ids only, read off the ciphertext, nothing decrypted
---@param lines string[] The file as it is on disk
---@return DyEncryptedRecipient[]
function M.recipients(lines)
  local found, seen = {}, {}
  -- Only the metadata: the data may have a key called `fp` or `arn` too
  local in_metadata = false
  for _, line in ipairs(lines) do
    if
      line:match('^sops:')
      or line:match('^%s*"sops"%s*:')
      or line:match('^%[sops%]')
    then
      in_metadata = true
    end
    local metadata = in_metadata or line:match('^sops_') ~= nil
    for _, key in ipairs(metadata and RECIPIENT_KEYS or {}) do
      -- `key: v`, `"key": "v"`, `…__map_key=v`, `…__map_key = v`; the key
      -- at the start of the line or after `{`, `,`, `-` or a blank, so a
      -- JSON object on one line is read too
      local value = (' ' .. line):match(
        '[%s{,%-]"?' .. key.pattern .. '"?%s*:%s*"?([^"%s,}]+)'
      ) or line:match('__map_' .. key.pattern .. '%s*=%s*(%S+)')
      if
        value
        and value ~= ''
        and not value:find('ENC[', 1, true)
        and not seen[key.kind .. value]
      then
        seen[key.kind .. value] = true
        table.insert(found, { kind = key.kind, id = value })
      end
    end
  end
  return found
end

--- Show the recipients of the decrypted sops file of the current buffer
function M.keys()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].dy_encrypted ~= 'sops' then
    return notify('Recipients are read from a sops file', vim.log.levels.WARN)
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  local ok, lines = pcall(vim.fn.readfile, file)
  local recipients = ok and M.recipients(lines) or {}
  if #recipients == 0 then
    return notify('No recipient found in the metadata of ' .. file)
  end
  local out = { '# Recipients of ' .. vim.fn.fnamemodify(file, ':~:.'), '' }
  for _, recipient in ipairs(recipients) do
    table.insert(out, ('- %-8s %s'):format(recipient.kind, recipient.id))
  end
  vim.list_extend(out, {
    '',
    '`:DyEncryptedRotate updatekeys` applies the recipients of `.sops.yaml`,',
    '`:DyEncryptedRotate rotate` makes a new data key.',
  })
  require('util.scratch').open(out, {
    split = 'horizontal',
    filetype = 'markdown',
  })
end

--- The sops command of each rotation
M.ROTATIONS = {
  -- The recipients of the file set to what `.sops.yaml` says now
  updatekeys = function(file) return { 'sops', 'updatekeys', '--yes', file } end,
  -- A new data key, the values encrypted again under it
  rotate = function(file) return { 'sops', 'rotate', '--in-place', file } end,
}

--- Rotate the keys of the decrypted sops file of the current buffer, and
--- open it again
---@param how? 'updatekeys'|'rotate' `updatekeys` unless given
function M.rotate(how)
  how = how or 'updatekeys'
  local bufnr = vim.api.nvim_get_current_buf()
  if not M.ROTATIONS[how] then
    return notify('Unknown rotation: ' .. how, vim.log.levels.ERROR)
  end
  if vim.b[bufnr].dy_encrypted ~= 'sops' then
    return notify(
      'Only a sops file is rotated here: Ansible Vault asks for its password',
      vim.log.levels.WARN
    )
  end
  if vim.bo[bufnr].modified then
    return notify(
      'Write the file first: rotating reads it from disk',
      vim.log.levels.WARN
    )
  end
  if vim.fn.executable('sops') ~= 1 then
    return notify('sops is not installed', vim.log.levels.ERROR)
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  local answer = vim.fn.confirm(
    ('%s %s?'):format(
      how == 'rotate' and 'Make a new data key for' or 'Apply .sops.yaml to',
      vim.fn.fnamemodify(file, ':~:.')
    ),
    '&Yes\n&No',
    2
  )
  if answer ~= 1 then return end
  local done = how == 'rotate' and 'New data key' or 'Recipients updated'
  run(M.ROTATIONS[how](file), {
    cwd = vim.fs.dirname(file),
    text = true,
  }, function(result)
    if not result or result.code ~= 0 then
      return notify(
        'sops failed: ' .. (result and failure('sops', result) or 'not run'),
        vim.log.levels.ERROR
      )
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then return notify(done) end
    -- Edited while sops ran: reading the file again would lose the edits
    if vim.bo[bufnr].modified then
      return notify(
        done .. '; the buffer has changes, so it was not read again',
        vim.log.levels.WARN
      )
    end
    -- Decrypted again from the file as rotated, unless edited meanwhile
    local clear = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    decrypt_into(
      bufnr,
      'sops',
      nil,
      function()
        return not vim.bo[bufnr].modified
          and vim.deep_equal(
            clear,
            vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
          )
      end,
      function(decrypted)
        notify(
          decrypted and done or (done .. '; the buffer was not read again'),
          decrypted and vim.log.levels.INFO or vim.log.levels.WARN
        )
      end
    )
  end)
end

return M
