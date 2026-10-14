--- A record of what each AI integration was handed, and what it was refused
---
--- `util.ai_guard` decides, at the one place each integration reads a buffer
--- or a path, whether it may. A notification says once what was stopped,
--- and nothing says what went out. This keeps those decisions -- which
--- integration, which file, when, and whether it went out or was turned
--- down -- so what left the editor can be looked back on, not only what was
--- kept in.
---
--- Only the name of what was handed over is kept, and a line range at most,
--- never its text: a log of what reached an AI must not become one more copy
--- of it.
local M = {}

---@class DyAiAuditEntry
---@field time integer Seconds since the epoch
---@field integration string `Copilot`, `Avante`, `sidekick`, `Claude Code`
---@field action 'sent'|'refused'
---@field what string The path handed over, or the name of the buffer
---@field detail? string How: `attached`, `selection`, `lines 3-9`, ...

--- Entries kept for `:DyAiGuardLog`, of this session alone
local MAX_ENTRIES = 500

--- Seconds within which the same handover is not logged again
---
--- Claude Code is handed the selection on every cursor move and Copilot the
--- buffer on every change. One line per file and minute says as much as a
--- hundred would.
local REPEAT_WINDOW = 60

--- The size the log file is allowed before its older half is dropped
local MAX_FILE_BYTES = 1024 * 1024

--- Entries of this session, oldest first
---@type DyAiAuditEntry[]
M.entries = {}

--- When each handover was last logged, by `key`
---@type table<string, integer>
local last_logged = {}

--- Where the entries of every session are appended, one JSON object a line
---@return string
function M.file()
  return vim.fs.joinpath(
    vim.fn.stdpath('state') --[[@as string]],
    'dyneo',
    'ai_audit.jsonl'
  )
end

--- What a buffer is called in the log: its path, or what stands in for one
---@param bufnr integer
---@return string
function M.describe_buffer(bufnr)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return ('[buffer %d]'):format(bufnr)
  end
  local name = vim.api.nvim_buf_get_name(bufnr)
  if name == '' then return ('[No Name %d]'):format(bufnr) end
  return vim.fs.normalize(name)
end

--- Keep the file from growing without end: past the limit, only its newer
--- half stays
---@param path string
local function rotate(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size <= MAX_FILE_BYTES then return end
  local lines = vim.fn.readfile(path)
  vim.fn.writefile(
    vim.list_slice(lines, math.floor(#lines / 2) + 1, #lines),
    path
  )
end

--- Append `entry` to the log file
---
--- A failure to write -- a read-only state directory, a full disk -- leaves
--- the entry in this session's list and says nothing: the integration it
--- records has already been let through or turned down either way.
---@param entry DyAiAuditEntry
local function persist(entry)
  local path = M.file()
  pcall(function()
    -- It names sensitive files and when they were reached for: this user's
    -- business only, whatever the umask says
    vim.fn.mkdir(vim.fs.dirname(path), 'p', '0700')
    local fd = assert(vim.uv.fs_open(path, 'a', tonumber('600', 8)))
    vim.uv.fs_write(fd, vim.json.encode(entry) .. '\n')
    vim.uv.fs_close(fd)
    rotate(path)
  end)
end

--- Log that `integration` was handed `what`, or refused it
---@param integration string
---@param action 'sent'|'refused'
---@param what string A path, or `describe_buffer` of a buffer
---@param detail? string
---@param now? integer Seconds since the epoch, for the specs
---@return boolean logged False when the same handover was logged just now
function M.record(integration, action, what, detail, now)
  now = now or os.time()
  local key = table.concat({ integration, action, what, detail or '' }, '\0')
  if last_logged[key] and now - last_logged[key] < REPEAT_WINDOW then
    return false
  end
  last_logged[key] = now

  ---@type DyAiAuditEntry
  local entry = {
    time = now,
    integration = integration,
    action = action,
    what = what,
    detail = detail,
  }
  table.insert(M.entries, entry)
  if #M.entries > MAX_ENTRIES then table.remove(M.entries, 1) end
  persist(entry)
  return true
end

--- `record` for a buffer rather than a path
---
--- A buffer that is not a file -- a terminal, a picker, the chat of the very
--- integration asking -- is not logged: there is nothing of the user's in it
--- worth tracing back.
---@param integration string
---@param action 'sent'|'refused'
---@param bufnr integer
---@param detail? string
---@return boolean logged
function M.record_buffer(integration, action, bufnr, detail)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  -- `acwrite` is a file too, written by a handler of its own: a decrypted
  -- one, the most worth tracing of all
  if
    not vim.api.nvim_buf_is_valid(bufnr)
    or not vim.list_contains({ '', 'acwrite' }, vim.bo[bufnr].buftype)
  then
    return false
  end
  return M.record(integration, action, M.describe_buffer(bufnr), detail)
end

--- Every entry of the log file, of every session, oldest first
---
--- A line that does not decode -- cut short by a crash -- is skipped.
---@return DyAiAuditEntry[]
function M.history()
  local path = M.file()
  if not vim.uv.fs_stat(path) then return {} end
  local entries = {}
  for _, line in ipairs(vim.fn.readfile(path)) do
    local ok, entry = pcall(vim.json.decode, line)
    if ok and type(entry) == 'table' and entry.time then
      table.insert(entries, entry)
    end
  end
  return entries
end

--- One line of `:DyAiGuardLog`
---@param entry DyAiAuditEntry
---@return string
function M.format(entry)
  local line = ('%s  %-7s  %-11s  %s'):format(
    os.date('%Y-%m-%d %H:%M:%S', entry.time),
    entry.action,
    entry.integration,
    vim.fn.fnamemodify(entry.what, ':~:.')
  )
  if entry.detail and entry.detail ~= '' then
    line = line .. '  (' .. entry.detail .. ')'
  end
  return line
end

--- Show `entries` newest first, in a scratch window of their own
---@param entries DyAiAuditEntry[]
---@param title string
function M.show(entries, title)
  local lines = { title, '' }
  for index = #entries, 1, -1 do
    table.insert(lines, M.format(entries[index]))
  end
  if #entries == 0 then table.insert(lines, 'Nothing was handed over.') end

  require('util.scratch').open(
    lines,
    { split = 'horizontal', filetype = 'dyneo-ai-audit' }
  )
end

--- `:DyAiGuardLog`, and `:DyAiGuardLog!` for every session the file still holds
function M.command()
  vim.api.nvim_create_user_command('DyAiGuardLog', function(args)
    if args.bang then
      return M.show(
        M.history(),
        'Handed to the AI integrations, every session (' .. M.file() .. ')'
      )
    end
    M.show(M.entries, 'Handed to the AI integrations, this session')
  end, {
    bang = true,
    desc = 'What the AI integrations were handed, or with ! in every session',
  })
end

--- Forget this session's entries, for the specs
function M.reset()
  M.entries = {}
  last_logged = {}
end

return M
