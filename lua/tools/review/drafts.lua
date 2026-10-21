--- Draft comments of a review and their marks in diff buffers
---
--- A draft is added, changed and sent from here, and drawn as a sign plus
--- end-of-line text. An AI-written draft has its own sign, colour and label
--- so it is never mistaken for the reviewer's own words or for a thread; an
--- AI draft nobody kept or edited is never sent. The marker lives in the
--- editor only: nothing posted to a forge carries it. No message here names
--- a draft's text.
local M = {}

M.HL = {
  draft = 'DyReviewDraft',
  ai = 'DyReviewAi',
  ai_pending = 'DyReviewAiPending',
  ai_sign = 'DyReviewAiSign',
  thread = 'DyReviewThread',
}

M.AI_SIGN = '󰚩'
M.DRAFT_SIGN = '󰏫'
M.THREAD_SIGN = '󰍩'

--- Longest first line shown as virtual text
M.LABEL_WIDTH = 60

local LINKS = {
  [M.HL.draft] = 'DiagnosticInfo',
  [M.HL.ai] = 'DiagnosticHint',
  [M.HL.ai_pending] = 'DiagnosticWarn',
  [M.HL.ai_sign] = 'DiagnosticWarn',
  [M.HL.thread] = 'Comment',
}

local ns = vim.api.nvim_create_namespace('dy_review')
local counter = 0

--- Define the highlight groups; a user's own definition wins
local function define_highlights()
  for name, link in pairs(LINKS) do
    vim.api.nvim_set_hl(0, name, { default = true, link = link })
  end
end

define_highlights()
vim.api.nvim_create_autocmd('ColorScheme', {
  group = vim.api.nvim_create_augroup('dy_review_drafts', { clear = true }),
  callback = define_highlights,
})

--- A fresh local id
---@return string
local function new_id()
  counter = counter + 1
  local time = ('%d.%d'):format(os.time(), vim.uv.hrtime())
  return vim.fn.sha256(time .. counter):sub(1, 12)
end

--- Add a reviewer's own draft to `state`
---@param state DyReviewState
---@param fields table  path, side, line, body and the optional fields
---@return DyReviewDraft
function M.add(state, fields)
  local draft = vim.tbl_extend('force', fields, {
    id = new_id(),
    origin = 'user',
    state = 'ready',
  })
  state.drafts[#state.drafts + 1] = draft
  return draft
end

--- The states `set_state` may give a draft of each origin
---
--- `edited` is reached only through `set_body`. A dropped AI draft may be
--- kept again, since any explicit action counts as looking at it. A forge
--- draft is never dropped here.
local ALLOWED = {
  ai = { pending = true, kept = true, dropped = true },
  user = { ready = true, dropped = true },
  forge = { ready = true },
}

--- Change a draft's state, within what its origin allows
---@param draft DyReviewDraft
---@param new_state 'ready'|'pending'|'kept'|'edited'|'dropped'
---@return boolean ok
---@return string? reason
function M.set_state(draft, new_state)
  local allowed = ALLOWED[draft.origin]
  if not (allowed and allowed[new_state]) then
    if draft.origin == 'forge' then
      return false, 'a draft pending on the forge cannot be changed here'
    end
    return false,
      ('a %s draft cannot become %s'):format(draft.origin, new_state)
  end
  draft.state = new_state
  return true
end

--- Change a draft's body; an AI draft becomes `edited`
---@param draft DyReviewDraft
---@param body string
---@return boolean ok
---@return string? reason
function M.set_body(draft, body)
  if draft.origin == 'forge' then
    return false, 'a draft pending on the forge cannot be edited here'
  end
  draft.body = body
  if draft.origin == 'ai' then draft.state = 'edited' end
  return true
end

--- Whether `line` (or the range `start_line`..`line`) lies in one hunk
---@param hunks DyReviewHunks
---@param side 'old'|'new'
---@param line integer
---@param start_line? integer
---@return boolean
function M.in_hunk(hunks, side, line, start_line)
  local first = math.min(start_line or line, line)
  local last = math.max(start_line or line, line)
  for _, hunk in ipairs(hunks[side] or {}) do
    if first >= hunk[1] and last <= hunk[2] then return true end
  end
  return false
end

--- Swap the pending AI drafts for `new`, keeping kept and edited ones
---@param state DyReviewState
---@param new DyReviewDraft[]
---@param head? string The head the pass read, for a draft that names none
function M.replace_ai(state, new, head)
  local result = {}
  for _, draft in ipairs(state.drafts) do
    if not (draft.origin == 'ai' and draft.state == 'pending') then
      result[#result + 1] = draft
    end
  end
  for _, draft in ipairs(new) do
    draft.id = draft.id or new_id()
    draft.head = draft.head or head
    draft.origin = 'ai'
    draft.state = 'pending'
    result[#result + 1] = draft
  end
  state.drafts = result
end

--- The first line of `body`, cut to `LABEL_WIDTH` characters
---@param body? string
---@return string
local function first_line(body)
  local line = vim.split(body or '', '\n', { plain = true })[1] or ''
  if vim.fn.strchars(line) > M.LABEL_WIDTH then
    line = vim.fn.strcharpart(line, 0, M.LABEL_WIDTH - 1) .. '…'
  end
  return line
end

--- What a draft's label and list entry add when it carries a suggestion
M.SUGGESTION_MARK = ' + suggestion'

--- The first line of a draft's body, and whether it carries a suggestion,
--- for a label
---@param draft DyReviewDraft
---@return string
function M.summary(draft)
  return first_line(draft.body)
    .. (draft.suggestion and M.SUGGESTION_MARK or '')
end

--- Sign, label and group of a draft
---@param draft DyReviewDraft
---@return string sign, string label, string group, string sign_group
local function style(draft)
  local text = M.summary(draft)
  if draft.origin == 'ai' then
    local pending = draft.state == 'pending'
    local group = pending and M.HL.ai_pending or M.HL.ai
    local label = ('%s AI %s: %s'):format(
      M.AI_SIGN,
      draft.severity or 'comment',
      text
    )
    return M.AI_SIGN, label, group, M.HL.ai_sign
  end
  if draft.origin == 'forge' then
    return M.DRAFT_SIGN,
      ('%s pending on forge: %s'):format(M.DRAFT_SIGN, text),
      M.HL.draft,
      M.HL.draft
  end
  return M.DRAFT_SIGN,
    ('%s draft: %s'):format(M.DRAFT_SIGN, text),
    M.HL.draft,
    M.HL.draft
end

--- Draw the drafts and threads of `path` on `side` into `bufnr`
---
--- Works on any valid buffer (a worktree file or a virtual diff buffer); an
--- invalid one is ignored.
---@param bufnr integer
---@param path string
---@param side 'old'|'new'
---@param state DyReviewState
---@param threads DyReviewThread[]
function M.draw(bufnr, path, side, state, threads)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(bufnr)

  ---@param line integer
  ---@param sign string
  ---@param sign_group string
  ---@param label string
  ---@param group string
  local function mark(line, sign, sign_group, label, group)
    local row = math.min(math.max(line, 1), count) - 1
    pcall(vim.api.nvim_buf_set_extmark, bufnr, ns, row, 0, {
      sign_text = sign,
      sign_hl_group = sign_group,
      virt_text = { { label, group } },
      virt_text_pos = 'eol',
      hl_mode = 'combine',
    })
  end

  for _, draft in ipairs(state.drafts) do
    if
      draft.path == path
      and draft.side == side
      and draft.state ~= 'dropped'
      and not draft.posted
    then
      local sign, label, group, sign_group = style(draft)
      mark(draft.line, sign, sign_group, label, group)
    end
  end
  for _, thread in ipairs(threads or {}) do
    if thread.path == path and thread.side == side and thread.line then
      local n = #thread.comments
      local label = ('%s %d comment%s%s'):format(
        M.THREAD_SIGN,
        n,
        n == 1 and '' or 's',
        thread.resolved and ' (resolved)' or ''
      )
      mark(thread.line, M.THREAD_SIGN, M.HL.thread, label, M.HL.thread)
    end
  end
end

return M
