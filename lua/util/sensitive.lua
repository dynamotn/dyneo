--- Files whose content must never reach an AI service
---
--- Copilot's language server is enabled for every filetype, and a language
--- server is sent the whole text of each buffer it attaches to -- before a
--- single suggestion is asked for. Opening a `.env` or a private key is enough
--- to upload it. What counts as sensitive is listed once, in
--- `config.sensitive`, and every integration that sends buffers away asks the
--- same question here instead of keeping a copy of the list that drifts.

local config = require('config.sensitive')

local M = {}

---@param path string Absolute, normalized path
---@return boolean
local function path_is_sensitive(path)
  -- Lower case throughout: on macOS `~/.SSH/ID_RSA` is the same file
  path = path:lower()
  local name = vim.fs.basename(path)
  for _, pattern in ipairs(config.name_patterns) do
    if name:match(pattern) then return true end
  end
  for _, pattern in ipairs(config.path_patterns) do
    if path:match(pattern) then return true end
  end
  -- The path itself as well: `~/.ssh` handed over as a directory is all of it
  if config.dirs[name] then return true end
  for dir in vim.fs.parents(path) do
    if config.dirs[vim.fs.basename(dir)] then return true end
  end
  for _, root in ipairs(config.paths) do
    root = vim.fs.normalize(root):lower()
    if path == root or vim.startswith(path, root .. '/') then return true end
  end
  return false
end

--- Whether a file's content must not leave the machine
---
--- Both the path as given and the path it resolves to are checked: in a
--- chezmoi `mode: symlink` home, `~/.config/foo` may be a link into the
--- repository's `secrets/`, and either name alone would miss one of the two.
---@param path string File path, relative to the working directory or absolute
---@return boolean
M.is_sensitive_path = function(path)
  if path == '' then return false end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if path_is_sensitive(path) then return true end

  local real = vim.uv.fs_realpath(path)
  return real ~= nil
    and real ~= path
    and path_is_sensitive(vim.fs.normalize(real))
end

--- The credential format `text` has the shape of, if any
---
--- The shape half of the question, asked of one string: a line of a buffer on
--- the way to an AI, or the value `camouflage.nvim` is about to show on
--- screen. `is_secret_key` is the other half, and both read their patterns
--- from `config.sensitive` so the two features cannot drift apart.
---@param text string?
---@return string? name The rule that matched, as it is reported
M.secret_format = function(text)
  if type(text) ~= 'string' then return nil end
  for _, rule in ipairs(config.content_patterns) do
    if text:find(rule.pattern) then return rule.name end
  end
  return nil
end

--- Whether `key` is the name of a value worth hiding
---@param key string?
---@return boolean
M.is_secret_key = function(key)
  if type(key) ~= 'string' then return false end
  key = key:lower()
  for _, pattern in ipairs(config.key_patterns) do
    if key:find(pattern) then return true end
  end
  return false
end

--- The rule each line of a buffer matches, `false` for none, kept current by
--- `nvim_buf_attach`: an edit costs a scan of the lines it touched, not of
--- the whole buffer, which the guards would otherwise read again on every
--- keystroke
---@class DySensitiveScan
---@field lines (string|false)[]
---@field tick? integer The change `found` was worked out for
---@field found? { name: string, line: integer }[]

---@type table<integer, DySensitiveScan>
local scans = {}

---@param bufnr integer
---@param first integer
---@param last integer
---@return (string|false)[]
local function scan_lines(bufnr, first, last)
  local out = {}
  for index, line in
    ipairs(vim.api.nvim_buf_get_lines(bufnr, first, last, false))
  do
    out[index] = M.secret_format(line) or false
  end
  return out
end

--- Put the scan of lines `first` to `last_old` (zero-based, end exclusive)
--- of `lines` in place of what they were, now that they are `fresh`
---@param lines (string|false)[]
---@param first integer
---@param last_old integer
---@param fresh (string|false)[]
local function splice(lines, first, last_old, fresh)
  local count = #lines
  local delta = #fresh - (last_old - first)
  if delta > 0 then
    for index = count, last_old + 1, -1 do
      lines[index + delta] = lines[index]
    end
  elseif delta < 0 then
    for index = last_old + 1, count do
      lines[index + delta] = lines[index]
    end
    for index = count + delta + 1, count do
      lines[index] = nil
    end
  end
  for index, value in ipairs(fresh) do
    lines[first + index] = value
  end
end

--- The scan of `bufnr`, started and attached on first use
---@param bufnr integer
---@return DySensitiveScan
local function scan_of(bufnr)
  if scans[bufnr] then return scans[bufnr] end
  ---@type DySensitiveScan
  local scan = { lines = scan_lines(bufnr, 0, -1) }
  local forget = function(_, buf)
    if scans[buf] == scan then scans[buf] = nil end
    return true
  end
  local attached = vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, buf, _, first, last_old, last_new)
      if scans[buf] ~= scan then return true end
      splice(scan.lines, first, last_old, scan_lines(buf, first, last_new))
      scan.tick = nil
    end,
    on_reload = forget,
    on_detach = forget,
  })
  -- Not kept when no change can reach it: it would go stale
  if attached then scans[bufnr] = scan end
  return scan
end

--- The credential formats a buffer holds, whatever it is called
---
--- Only the text is read: a buffer of a file that was never written, a
--- scratch buffer and a terminal's output are all searched the same way. A
--- buffer past `content_max_bytes` is not searched at all, and reads as
--- sensitive: what a search cut short missed could be a key.
---@param bufnr integer
---@return { name: string, line: integer }[] found
---@return boolean partial Whether the buffer was too large to search
local function secrets_in_buffer(bufnr)
  local lines = vim.api.nvim_buf_line_count(bufnr)
  if vim.api.nvim_buf_get_offset(bufnr, lines) > config.content_max_bytes then
    return {}, true
  end
  local scan = scan_of(bufnr)
  local tick = vim.api.nvim_buf_get_changedtick(bufnr)
  if scan.tick ~= tick or not scan.found then
    local found, seen = {}, {}
    for line, name in ipairs(scan.lines) do
      if name and not seen[name] then
        seen[name] = true
        table.insert(found, { name = name, line = line })
      end
    end
    scan.found, scan.tick = found, tick
  end
  return vim.deepcopy(scan.found), false
end

--- The namespace of `betterleaks`' diagnostics, `false` while it has none
---@type integer|false|nil
local leaks_namespace

--- What `betterleaks` found in a buffer, as its diagnostics
---
--- `betterleaks` already runs over every buffer as a linter of its own, with
--- hundreds of rules behind it and the secret redacted out of what it
--- reports. Reading what it left behind costs nothing and asks nothing of it:
--- no second process, and nothing sent anywhere. It only answers once it has
--- run, though -- on a write, a read or leaving insert mode -- which is why
--- the patterns above are there as well, and why they are the ones that can
--- answer the instant a key is pressed.
---
--- nvim-lint names the namespace of a linter after it, so only that one is
--- read: `vim.diagnostic.get` copies every diagnostic it hands back.
---@param bufnr integer
---@return { name: string, line: integer }[]
local function leaks_in_buffer(bufnr)
  local found = {}
  -- Asked per keystroke, and `nvim_get_namespaces` builds the whole table:
  -- a miss is kept too, until the next diagnostics arrive, which is the
  -- earliest the linter can have made its namespace
  if leaks_namespace == nil then
    leaks_namespace = vim.api.nvim_get_namespaces().betterleaks or false
    if not leaks_namespace then
      vim.api.nvim_create_autocmd('DiagnosticChanged', {
        group = vim.api.nvim_create_augroup('dy_sensitive', { clear = true }),
        once = true,
        callback = function() leaks_namespace = nil end,
      })
    end
  end
  if not leaks_namespace then return found end
  for _, diagnostic in
    ipairs(vim.diagnostic.get(bufnr, { namespace = leaks_namespace }))
  do
    if diagnostic.source == 'betterleaks' then
      table.insert(found, {
        name = ('betterleaks %s'):format(diagnostic.code or 'finding'),
        line = diagnostic.lnum + 1,
      })
    end
  end
  return found
end

--- Let this buffer through the content check for as long as it is open
---
--- The way out of a pattern that matched something that is not a credential.
--- It says nothing about the name rules: a `.env` stays sensitive however
--- often it is allowed, since what that file is for is not in doubt.
---
--- `allowed = false` takes the waiver back, for a buffer that was let through
--- by mistake -- without it the only way back would be closing the buffer.
---@param bufnr? integer
---@param allowed? boolean Defaults to true
M.allow = function(bufnr, allowed)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.b[bufnr].dy_ai_guard_allow = allowed ~= false or nil
end

--- Whether the content check has been waived for a buffer
---@param bufnr integer
---@return boolean
M.is_allowed = function(bufnr)
  return vim.api.nvim_buf_is_valid(bufnr)
    and vim.b[bufnr].dy_ai_guard_allow == true
end

--- Hold a buffer back for a reason of its own, whatever its name or its text
---
--- For a buffer whose content is sensitive by where it came from rather than
--- by what it looks like: a file decrypted for editing, a Helm chart rendered
--- with its Secrets. Like the name rules, it cannot be waived.
---@param bufnr integer
---@param reason string Said by `:DyAiGuardCheck`
M.mark = function(bufnr, reason)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  vim.b[bufnr].dy_sensitive = reason
end

--- Why `bufnr` was marked sensitive, if it was
---@param bufnr integer
---@return string?
M.marked = function(bufnr)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(bufnr) then return nil end
  local reason = vim.b[bufnr].dy_sensitive
  return type(reason) == 'string' and reason or nil
end

--- Why a buffer must not leave the machine, in words, or nothing when it may
---
--- `opts.ignore_waiver` reports what a waived buffer would be held back for,
--- which is what `:DyAiGuardCheck` says over a buffer that has been allowed.
---@param bufnr? integer
---@param opts? { ignore_waiver?: boolean }
---@return string[]
M.reasons = function(bufnr, opts)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(bufnr) then return {} end

  local reasons = {}
  local filetype = vim.bo[bufnr].filetype
  if vim.list_contains(config.filetypes, filetype) then
    table.insert(reasons, ('filetype %s'):format(filetype))
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if M.is_sensitive_path(name) then
    table.insert(reasons, ('path %s'):format(vim.fn.fnamemodify(name, ':~')))
  end
  local marked = M.marked(bufnr)
  if marked then table.insert(reasons, marked) end
  if M.is_allowed(bufnr) and not (opts or {}).ignore_waiver then
    return reasons
  end
  local found, partial = secrets_in_buffer(bufnr)
  vim.list_extend(found, leaks_in_buffer(bufnr))
  for _, secret in ipairs(found) do
    table.insert(reasons, ('%s on line %d'):format(secret.name, secret.line))
  end
  if partial then
    table.insert(
      reasons,
      ('larger than %d KiB, too large to search'):format(
        config.content_max_bytes / 1024
      )
    )
  end
  return reasons
end

--- `is_sensitive_path` of each buffer name asked about: a name keeps its
--- answer, and asking it again costs a `realpath` on every keystroke
---@type table<string, boolean>
local by_name = {}

--- Whether a buffer holds a file whose content must not leave the machine
---@param bufnr? integer Buffer number, the current one when nil or 0
---@return boolean
M.is_sensitive = function(bufnr)
  if bufnr == nil or bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(bufnr) then return false end
  if vim.list_contains(config.filetypes, vim.bo[bufnr].filetype) then
    return true
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  local by_path = by_name[name]
  if by_path == nil then
    by_path = M.is_sensitive_path(name)
    -- A name with no file behind it yet may get one later, as a symlink into
    -- a sensitive directory even: its answer is kept once there is a file
    if by_path or vim.uv.fs_stat(name) then by_name[name] = by_path end
  end
  if by_path then return true end
  if M.marked(bufnr) then return true end
  if M.is_allowed(bufnr) then return false end
  local found, partial = secrets_in_buffer(bufnr)
  return partial or #found > 0 or #(leaks_in_buffer(bufnr)) > 0
end

return M
