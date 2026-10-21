--- A review's marks and drafts, kept on disk
---
--- Which files the reviewer marked read, the head of the last submitted
--- review, and every draft comment (the reviewer's, the AI's and those
--- imported from the forge) live in one JSON file per review, so a crash, a
--- quit or a failed submit loses nothing. The file sits under
--- `stdpath('state')`, never in the repository, and holds comment text: it
--- is read and written here only, and no message names a draft's content.
local M = {}

local notify = require('util.notify').titled('Review')

---@class DyReviewDraft
---@field id string            local, `vim.fn.sha256(time .. counter)`:sub(1, 12)
---@field origin 'user'|'ai'|'forge'
---@field state 'ready'|'pending'|'kept'|'edited'|'dropped'
---@field path string
---@field side 'old'|'new'
---@field line integer
---@field start_line? integer
---@field body string
---@field suggestion? string[]
---@field severity? 'blocker'|'suggestion'|'question'|'nit'
---@field reply_to? string     forge thread id
---@field resolve? boolean
---@field file_level? boolean  line outside every hunk
---@field posted? string       forge id once sent
---@field done? string         head SHA of the whole submit it went out with
---@field head? string         head SHA it was written or imported on

---@class DyReviewState
---@field reviewed table<string, string>  path -> blob SHA
---@field last_head? string
---@field mark? integer  newest forge note or thread id of the last whole submit
---@field drafts DyReviewDraft[]

--- Whether `name` is one path segment that stays inside its parent
---@param name any
---@return boolean
local function safe_segment(name)
  return type(name) == 'string'
    and name ~= ''
    and name ~= '.'
    and name ~= '..'
    and not name:find('[/\\%z]')
end

--- Directory holding every review
---@return string
local function root()
  return vim.fs.joinpath(vim.fn.stdpath('state'), 'dyneo', 'review')
end

--- Where the state of review `id` of `remote` lives
---
--- A slug's slashes become directories (Azure DevOps slugs are
--- `org/project/repo`). A host, slug or id that would leave the review
--- directory is an error, not a path.
---@param remote DyForgeRemote
---@param id string
---@return string
function M.path(remote, id)
  local parts = { root() }
  if not safe_segment(remote.host) then
    error('review store: unsafe host', 2)
  end
  parts[#parts + 1] = remote.host
  if type(remote.slug) ~= 'string' then
    error('review store: unsafe slug', 2)
  end
  for _, segment in ipairs(vim.split(remote.slug, '/', { plain = true })) do
    if not safe_segment(segment) then error('review store: unsafe slug', 2) end
    parts[#parts + 1] = segment
  end
  if not safe_segment(id) then error('review store: unsafe id', 2) end
  parts[#parts + 1] = id .. '.json'
  return vim.fs.joinpath(unpack(parts))
end

--- Make the directory of `path` and every one up to `review/` private:
--- `mkdir` sets the mode of new directories only, and comment text is
--- private
---@param path string
local function private_dir(path)
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, 'p', '0700')
  local top = root()
  local current = dir
  while #current >= #top and vim.startswith(current, top) do
    vim.uv.fs_chmod(current, tonumber('700', 8))
    if current == top then break end
    current = vim.fs.dirname(current)
  end
end

--- Where the lock of review `id` of `remote` lives, beside its state
---@param remote DyForgeRemote
---@param id string
---@return string
local function lock_path(remote, id)
  return (M.path(remote, id):gsub('%.json$', '.lock'))
end

--- Whether process `pid` of this host is alive; one of another user, which
--- cannot be signalled, is
---@param pid integer
---@return boolean
local function alive(pid)
  local ok, err = vim.uv.kill(pid, 0)
  return ok == 0
    or (type(err) == 'string' and err:find('EPERM', 1, true) ~= nil)
end

--- Take the lock of review `id` of `remote` for this Neovim
---
--- One Neovim at a time reviews a pull request: two would each send the
--- drafts the other sent too. The lock is a private file holding the pid
--- and host of its owner; a lock whose owner is no longer alive on this
--- host is taken over. One of another host is never judged from here.
---@param remote DyForgeRemote
---@param id string
---@return boolean ok
---@return string? why Who holds it, when not
function M.lock(remote, id)
  local path = lock_path(remote, id)
  private_dir(path)
  local me, host = vim.uv.os_getpid(), vim.uv.os_gethostname()
  for _ = 1, 2 do
    local fd = vim.uv.fs_open(path, 'wx', tonumber('600', 8))
    if fd then
      vim.uv.fs_write(fd, ('%d\n%s\n'):format(me, host))
      vim.uv.fs_close(fd)
      return true
    end
    local read, lines = pcall(vim.fn.readfile, path)
    local pid = read and tonumber(lines[1]) or nil
    local owner = read and lines[2] or nil
    if pid == me and owner == host then return true end
    if pid and owner and owner ~= host then
      return false,
        ('This review is open in another Neovim (pid %d on %s): remove %s if it is not'):format(
          pid,
          owner,
          path
        )
    end
    if pid and alive(pid) then
      return false,
        ('This review is open in another Neovim (pid %d)'):format(pid)
    end
    -- Its owner is gone, or it holds nothing to tell one: taken over
    vim.uv.fs_unlink(path)
  end
  return false, 'Could not take the lock of this review: ' .. path
end

--- Let the lock of review `id` of `remote` go, if this Neovim holds it
---@param remote DyForgeRemote
---@param id string
function M.unlock(remote, id)
  local path = lock_path(remote, id)
  local read, lines = pcall(vim.fn.readfile, path)
  if
    read
    and tonumber(lines[1]) == vim.uv.os_getpid()
    and lines[2] == vim.uv.os_gethostname()
  then
    vim.uv.fs_unlink(path)
  end
end

--- A state with nothing marked and nothing drafted
---@return DyReviewState
local function empty() return { reviewed = {}, drafts = {} } end

--- Whether `state` has the shape of a stored review
---@param state any
---@return boolean
local function valid(state)
  return type(state) == 'table'
    and not (vim.islist(state) and next(state) ~= nil)
    and (state.reviewed == nil or type(state.reviewed) == 'table')
    and (state.drafts == nil or type(state.drafts) == 'table')
    and (state.last_head == nil or type(state.last_head) == 'string')
end

--- Read review `id` of `remote`
---
--- A missing file is an empty review. One that does not decode is renamed
--- `<file>.bad` (or `.bad.N` when one exists) and reported, so neither a
--- save nor a later bad file overwrites it.
---@param remote DyForgeRemote
---@param id string
---@return DyReviewState
function M.load(remote, id)
  local path = M.path(remote, id)
  if vim.uv.fs_stat(path) == nil then return empty() end
  local ok, lines = pcall(vim.fn.readfile, path)
  local decoded, state
  if ok then
    decoded, state = pcall(
      vim.json.decode,
      table.concat(lines, '\n'),
      { luanil = { object = true, array = true } }
    )
  end
  if not (ok and decoded and valid(state)) then
    local aside = path .. '.bad'
    local n = 0
    while vim.uv.fs_stat(aside) do
      n = n + 1
      aside = ('%s.bad.%d'):format(path, n)
    end
    local moved = vim.uv.fs_rename(path, aside)
    notify(
      moved and ('Unreadable review state kept as ' .. aside)
        or ('Unreadable review state left in place: ' .. path),
      vim.log.levels.WARN
    )
    return empty()
  end
  state.reviewed = state.reviewed or {}
  state.drafts = state.drafts or {}
  return state
end

--- Write review `id` of `remote`
---
--- The text goes to a temp file in the same directory first and is renamed
--- over the target, so a crash leaves the old state or the new, never half.
---@param remote DyForgeRemote
---@param id string
---@param state DyReviewState
function M.save(remote, id, state)
  local path = M.path(remote, id)
  local out = vim.tbl_extend('force', state, {
    reviewed = next(state.reviewed or {}) and state.reviewed
      or vim.empty_dict(),
    drafts = state.drafts or {},
  })
  private_dir(path)
  local temp = ('%s.tmp.%d'):format(path, vim.uv.os_getpid())
  if vim.fn.writefile({ vim.json.encode(out) }, temp) ~= 0 then
    vim.fn.delete(temp)
    error('review store: cannot write ' .. temp)
  end
  vim.uv.fs_chmod(temp, tonumber('600', 8))
  local ok, err = vim.uv.fs_rename(temp, path)
  if not ok then
    vim.fn.delete(temp)
    error('review store: cannot replace ' .. path .. ': ' .. tostring(err))
  end
end

return M
