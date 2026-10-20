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

---@class DyReviewState
---@field reviewed table<string, string>  path -> blob SHA
---@field last_head? string
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
--- `<file>.bad` and reported, so the next save cannot overwrite it silently.
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
  local dir = vim.fs.dirname(path)
  vim.fn.mkdir(dir, 'p')
  local temp = ('%s.tmp.%d'):format(path, vim.uv.os_getpid())
  if vim.fn.writefile({ vim.json.encode(out) }, temp) ~= 0 then
    vim.fn.delete(temp)
    error('review store: cannot write ' .. temp)
  end
  local ok, err = vim.uv.fs_rename(temp, path)
  if not ok then
    vim.fn.delete(temp)
    error('review store: cannot replace ' .. path .. ': ' .. tostring(err))
  end
end

return M
