--- What the reviewer does in the diff of a review
---
--- Comments, suggestions and replies are written in a Markdown float and kept
--- as drafts; threads are resolved with the review; AI drafts are kept, edited
--- or dropped; files are marked reviewed. Each change is saved at once.
local M = {}

local diff = require('tools.review.diff')
local drafts = require('tools.review.drafts')
local session = require('tools.review.session')
local store = require('tools.review.store')

local notify = require('util.notify').titled('Review')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- The keys of a review's diff buffers: `{ mode, lhs, rhs, desc }`
---@return table[]
function M.keys()
  local function current_mark()
    local path = diff.locate(vim.api.nvim_get_current_buf())
    if path then M.mark(path) end
  end
  return {
    { 'n', '<localleader>c', function() M.comment() end, 'Comment' },
    { 'x', '<localleader>c', function() M.comment() end, 'Comment on Lines' },
    {
      { 'n', 'x' },
      '<localleader>s',
      function() M.comment({ suggest = true }) end,
      'Suggest a Change',
    },
    { 'n', '<localleader>r', M.reply, 'Reply to Thread' },
    { 'n', '<localleader>R', M.toggle_resolve, 'Toggle Resolving Thread' },
    { 'n', '<localleader>m', current_mark, 'Mark File Reviewed' },
    {
      'n',
      '<localleader>k',
      function() M.ai_action('keep') end,
      'Keep AI Draft',
    },
    {
      'n',
      '<localleader>e',
      function() M.ai_action('edit') end,
      'Edit Draft',
    },
    {
      'n',
      '<localleader>x',
      function() M.ai_action('drop') end,
      'Drop Draft',
    },
    { 'n', ']a', function() M.jump_ai(1) end, 'Next Pending AI Draft' },
    { 'n', '[a', function() M.jump_ai(-1) end, 'Prev Pending AI Draft' },
  }
end

--- Where the cursor is in the review's diff
---@return DyReviewSession? s
---@return string? path
---@return DyReviewSide? side
---@return integer line
local function here()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local s = session.need()
  if not s then return nil, nil, nil, line end
  local path, side = diff.locate(vim.api.nvim_get_current_buf())
  if not path then
    notify('Not in the diff of the review', WARN)
    return nil, nil, nil, line
  end
  return s, path, side, line
end

--- Call `cb` with the hunks of `path`, read now when they were left out
---@param s DyReviewSession
---@param path string
---@param cb fun(hunks: DyReviewHunks)
local function with_hunks(s, path, cb)
  if s.hunks[path] then return cb(s.hunks[path]) end
  local file = session.file_of(s, path)
  session.load_hunks(s, { file or { path = path } }, function(err)
    if not s.hunks[path] then
      return notify(
        ('Could not read the diff of %s: %s'):format(path, err or '?'),
        ERROR
      )
    end
    cb(s.hunks[path])
  end)
end

--- Change the drafts of review `s` and save them. A float saved after its
--- review closed changes the review open on that pull request now, or else
--- its state on disk, so no text written is lost.
---@param s DyReviewSession
---@param change fun(state: DyReviewState)
local function apply(s, change)
  local live = session.current()
  if live and session.same(live, s.remote, s.pull.id) then
    change(live.state)
    return session.changed(live)
  end
  local loaded, state = pcall(store.load, s.remote, s.pull.id)
  if not loaded then
    return notify('Could not read the review: ' .. tostring(state), ERROR)
  end
  change(state)
  local saved, err = pcall(store.save, s.remote, s.pull.id, state)
  if not saved then
    return notify('Could not save the review: ' .. tostring(err), ERROR)
  end
  notify(('Kept in the closed review of !%s'):format(s.pull.id))
end

---@type integer
local editors = 0

--- A Markdown float to write a comment in; `:w` hands its lines to `on_save`
--- and closes it. `:q` on unsaved text is refused as for any file.
---@param title string
---@param lines string[]
---@param on_save fun(lines: string[])
local function editor(title, lines, on_save)
  editors = editors + 1
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bufnr, ('dyreview://draft/%d'):format(editors))
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = 'markdown'
  local width = math.max(math.min(80, vim.o.columns - 4), 20)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = 10,
    border = 'rounded',
    title = (' %s (:w saves) '):format(title),
    title_pos = 'center',
  })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      local text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.bo[bufnr].modified = false
      -- Closed after the command: the quit of `:wq` or `:x` closes the
      -- current window, which must still be the float when it runs
      vim.schedule(function()
        if vim.api.nvim_win_is_valid(win) then
          vim.api.nvim_win_close(win, true)
        end
      end)
      if vim.trim(table.concat(text, '\n')) == '' then
        return notify('Nothing written: no draft saved')
      end
      on_save(text)
    end,
  })
end

--- A fence of backticks longer than any run of them in `lines`
---@param lines string[]
---@return string
local function fence_for(lines)
  local longest = 2
  for _, line in ipairs(lines) do
    for run in line:gmatch('`+') do
      longest = math.max(longest, #run)
    end
  end
  return ('`'):rep(longest + 1)
end

--- The lines of `suggestion` as a fenced suggestion block
---@param suggestion string[]
---@return string[]
local function suggestion_block(suggestion)
  local fence = fence_for(suggestion)
  local block = { fence .. 'suggestion' }
  vim.list_extend(block, suggestion)
  block[#block + 1] = fence
  return block
end

--- What an edit float starts from: the body, then the suggestion the draft
--- carries, so nothing is sent that was not seen
---@param draft DyReviewDraft
---@return string[]
local function seed(draft)
  local lines = vim.split(draft.body or '', '\n', { plain = true })
  if draft.suggestion then
    if #lines == 1 and lines[1] == '' then lines = {} end
    if #lines > 0 then lines[#lines + 1] = '' end
    vim.list_extend(lines, suggestion_block(draft.suggestion))
  end
  return lines
end

--- The body and the suggested lines of an editor's text: the first
--- suggestion block, closed by a fence at least as long as it opened with
---@param lines string[]
---@return string body
---@return string[]? suggestion
local function parse(lines)
  local body, suggestion, fence = {}, nil, nil
  for _, line in ipairs(lines) do
    local open = not fence
      and not suggestion
      and line:match('^(```+)suggestion%s*$')
    local close = fence and line:match('^(```+)%s*$')
    if open then
      fence, suggestion = open, {}
    elseif close and #close >= #fence then
      fence = nil
    elseif fence then
      suggestion[#suggestion + 1] = line
    else
      body[#body + 1] = line
    end
  end
  return vim.trim(table.concat(body, '\n')), suggestion
end

--- Write a draft on the line or the lines under the cursor
---@param opts? { suggest?: boolean } Start from the lines as a suggestion
function M.comment(opts)
  opts = opts or {}
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local start_line ---@type integer?
  if vim.fn.mode():match('^[vV\22]') then
    local other = vim.fn.line('v')
    start_line, line = math.min(other, line), math.max(other, line)
    if start_line == line then start_line = nil end
    vim.cmd('normal! \27')
  end
  if opts.suggest and side ~= 'new' then
    return notify('A suggestion replaces lines of the new side', WARN)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  with_hunks(s, path, function(hunks)
    local fields = { path = path, side = side, line = line }
    fields.start_line = start_line
    -- The line numbers are those of this head
    fields.head = s.pull.head_sha
    if not drafts.in_hunk(hunks, side, line, start_line) then
      notify(
        ('Outside the diff: sent as a file comment naming line %d'):format(line),
        WARN
      )
      fields.file_level = true
    end
    local initial = {}
    if opts.suggest then
      local first = start_line or line
      initial = { '' }
      vim.list_extend(
        initial,
        suggestion_block(
          vim.api.nvim_buf_get_lines(bufnr, first - 1, line, false)
        )
      )
    end
    editor('Comment', initial, function(text)
      fields.body, fields.suggestion = parse(text)
      apply(s, function(state) drafts.add(state, fields) end)
    end)
  end)
end

--- The thread on the cursor's line
---@param s DyReviewSession
---@param path string
---@param side DyReviewSide
---@param line integer
---@return DyReviewThread?
local function thread_at(s, path, side, line)
  for _, thread in ipairs(s.threads) do
    if
      thread.path == path
      and thread.side == side
      and thread.line
      and line >= (thread.start_line or thread.line)
      and line <= thread.line
    then
      return thread
    end
  end
end

--- Reply to the thread under the cursor
function M.reply()
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local thread = thread_at(s, path, side, line)
  if not thread then return notify('No thread on this line', WARN) end
  editor('Reply', {}, function(text)
    local body = parse(text)
    apply(
      s,
      function(state)
        drafts.add(state, {
          path = path,
          side = side,
          line = thread.line,
          body = body,
          reply_to = thread.id,
          head = s.pull.head_sha,
        })
      end
    )
  end)
end

--- Resolve the thread under the cursor with the review, or take that back
function M.toggle_resolve()
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local thread = thread_at(s, path, side, line)
  if not thread then return notify('No thread on this line', WARN) end
  for i, draft in ipairs(s.state.drafts) do
    if
      draft.reply_to == thread.id
      and draft.origin == 'user'
      and not draft.posted
    then
      draft.resolve = not draft.resolve
      if not draft.resolve and draft.body == '' then
        table.remove(s.state.drafts, i)
      end
      notify(draft.resolve and 'Resolves with the review' or 'Left open')
      return session.changed(s)
    end
  end
  if thread.resolved then return notify('The thread is resolved already') end
  drafts.add(s.state, {
    path = path,
    side = side,
    line = thread.line,
    body = '',
    reply_to = thread.id,
    resolve = true,
    head = s.pull.head_sha,
  })
  notify('Resolves with the review')
  session.changed(s)
end

--- The shown draft on the cursor's line, an AI one first: a dropped draft
--- has no mark to act on
---@param s DyReviewSession
---@param path string
---@param side DyReviewSide
---@param line integer
---@return DyReviewDraft?
local function draft_at(s, path, side, line)
  local found ---@type DyReviewDraft?
  for _, draft in ipairs(s.state.drafts) do
    if
      draft.path == path
      and draft.side == side
      and not draft.posted
      and draft.state ~= 'dropped'
      and line >= (draft.start_line or draft.line)
      and line <= draft.line
      and (not found or draft.origin == 'ai')
    then
      found = draft
    end
  end
  return found
end

--- Keep, edit or drop the draft under the cursor
---@param action 'keep'|'edit'|'drop'
function M.ai_action(action)
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local draft = draft_at(s, path, side, line)
  if not draft then return notify('No draft on this line', WARN) end
  if action == 'edit' then
    if draft.origin == 'forge' then
      return notify('A draft pending on the forge cannot be edited here', WARN)
    end
    local id = draft.id
    return editor('Edit', seed(draft), function(text)
      local body, suggestion = parse(text)
      apply(s, function(state)
        for _, d in ipairs(state.drafts) do
          if d.id == id then
            local ok, why = drafts.set_body(d, body)
            if not ok then return notify(why or 'Cannot edit', WARN) end
            -- What the float showed is what is kept: a block taken out
            -- drops the suggestion, one typed in adds it
            d.suggestion = suggestion
            return
          end
        end
        notify('The draft is gone: the edit is not kept', WARN)
      end)
    end)
  end
  local ok, why =
    drafts.set_state(draft, action == 'keep' and 'kept' or 'dropped')
  if not ok then return notify(why or 'Cannot change the draft', WARN) end
  session.changed(s)
end

--- Move to the next (1) or previous (-1) pending AI draft, in this file or
--- in the next file that has one
---@param dir 1|-1
function M.jump_ai(dir)
  local s = session.need()
  if not s then return end
  local here_path, here_side = diff.locate(vim.api.nvim_get_current_buf())
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local order, n = {}, 0 ---@type table<string, integer>, integer
  for _, bucket in ipairs(s.buckets) do
    for _, file in ipairs(bucket.files) do
      n = n + 1
      order[file.path] = n
    end
  end
  local list = vim.tbl_filter(
    function(d) return d.origin == 'ai' and d.state == 'pending' end,
    s.state.drafts
  )
  table.sort(list, function(a, b)
    local pa, pb = order[a.path] or math.huge, order[b.path] or math.huge
    if pa ~= pb then return pa < pb end
    return a.line < b.line
  end)
  if dir < 0 then list = vim.fn.reverse(list) end
  local pos = order[here_path] or 0
  for _, draft in ipairs(list) do
    local p = order[draft.path] or math.huge
    local ahead = dir > 0 and (p > pos or (p == pos and draft.line > line))
      or dir < 0 and (p < pos or (p == pos and draft.line < line))
    if ahead then
      if draft.path == here_path and draft.side == here_side then
        return vim.api.nvim_win_set_cursor(0, { draft.line, 0 })
      end
      s.jump = { path = draft.path, side = draft.side, line = draft.line }
      return require('tools.review').show(draft.path)
    end
  end
  notify('No pending AI draft that way')
end

--- Mark `path` reviewed at its blob, or take the mark back
---@param path string
function M.mark(path)
  local s = session.need()
  if not s then return end
  local file = session.file_of(s, path)
  if not file then return end
  local blob = file.blob or ''
  s.state.reviewed[path] = s.state.reviewed[path] ~= blob and blob or nil
  session.changed(s)
end

return M
