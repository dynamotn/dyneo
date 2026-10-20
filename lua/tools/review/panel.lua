--- The file list of a review, for triage
---
--- A side panel in the review's diff tab: the files of the pull request in
--- buckets (source first, risky files first), what was reviewed and what
--- changed since, and how many AI drafts wait on each file. `render` is pure,
--- so the layout is specced; `open` draws it in a window of its own.
local M = {}

--- Width of the panel window, in columns
M.WIDTH = 40

--- Longest path column, so one very deep path does not push the counts away
M.PATH_WIDTH = 48

--- Lines of the AI summary shown, the last one `…` when it is longer
M.SUMMARY_LINES = 8

--- The name of each bucket in the panel
---@type table<DyReviewKind, string>
M.LABELS = {
  source = 'Source',
  tests = 'Tests',
  config = 'Config & infra',
  docs = 'Docs',
  generated = 'Generated & locks',
}

---@class DyReviewPanelRow
---@field kind? DyReviewKind A bucket's line
---@field path? string A file's line
---@field ci? boolean The CI line

--- `+added -removed`, each only when there is some
---@param added integer
---@param removed integer
---@param binary? boolean
---@return string
local function counts(added, removed, binary)
  if binary then return 'binary' end
  local parts = {}
  if added > 0 then parts[#parts + 1] = '+' .. added end
  if removed > 0 then parts[#parts + 1] = '-' .. removed end
  return table.concat(parts, ' ')
end

--- `n` and `word`, made plural unless `n` is one
---@param n integer
---@param word string
---@return string
local function count_of(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

--- Whether `kind` is folded: what the reviewer chose, else only generated
---@param session DyReviewSession
---@param kind DyReviewKind
---@return boolean
local function folded(session, kind)
  local chosen = (session.collapsed or {})[kind]
  if chosen == nil then return kind == 'generated' end
  return chosen
end

--- `✓` reviewed as it is now, `⟳` changed since it was marked, else blank
---@param session DyReviewSession
---@param file DyReviewFile
---@return string
function M.mark(session, file)
  local seen = session.state.reviewed[file.path]
  if not seen then return ' ' end
  return seen == (file.blob or '') and '✓' or '⟳'
end

--- Pending AI drafts of each path
---@param drafts DyReviewDraft[]
---@return table<string, integer>
local function pending_ai(drafts)
  local by_path = {}
  for _, draft in ipairs(drafts) do
    if draft.origin == 'ai' and draft.state == 'pending' then
      by_path[draft.path] = (by_path[draft.path] or 0) + 1
    end
  end
  return by_path
end

--- `text` padded with spaces to `width` display columns
---@param text string
---@param width integer
---@return string
local function pad(text, width)
  return text .. (' '):rep(math.max(width - vim.fn.strdisplaywidth(text), 0))
end

--- The words of `text` in lines of at most `width` columns; a blank line
--- of it is let go, a word wider than `width` gets a line of its own
---@param text string
---@param width integer
---@return string[]
local function wrap(text, width)
  local lines = {}
  for paragraph in text:gmatch('[^\n]+') do
    local line = ''
    for word in paragraph:gmatch('%S+') do
      if line == '' then
        line = word
      elseif vim.fn.strdisplaywidth(line .. ' ' .. word) <= width then
        line = line .. ' ' .. word
      else
        lines[#lines + 1] = line
        line = word
      end
    end
    if line ~= '' then lines[#lines + 1] = line end
  end
  return lines
end

--- The CI line of the header: the runs counted by state, `(by branch)` when
--- any run is keyed on the branch rather than the head commit, and the sources
--- that could not be asked. Nil before any fetch was asked for.
---@param session DyReviewSession
---@return string?
function M.ci_line(session)
  local ci = session.ci
  if not ci then return session.ci_loading and ' CI: asking…' or nil end
  local counts_of, keyed = {}, {}
  for _, run in ipairs(ci.runs) do
    counts_of[run.state] = (counts_of[run.state] or 0) + 1
    if run.by ~= 'commit' then keyed[run.by] = true end
  end
  local parts = {}
  for _, state in ipairs(require('tools.review.ci').STATES) do
    if counts_of[state] then
      parts[#parts + 1] = ('%d %s'):format(counts_of[state], state)
    end
  end
  local line = table.concat(parts, ' · ')
  local by = vim.tbl_filter(function(key) return keyed[key] end, {
    'branch',
    'name',
  })
  if #by > 0 then line = line .. ' (by ' .. table.concat(by, ', ') .. ')' end
  local pieces = { line ~= '' and line or nil }
  if #ci.errors > 0 then
    local names = vim.tbl_map(
      function(err) return err:match('^[^:]+') end,
      ci.errors
    )
    pieces[#pieces + 1] = 'could not ask ' .. table.concat(names, ', ')
  end
  if #pieces == 0 then pieces[1] = 'no runs' end
  -- Sources held back until the code may be trusted: not a failure
  vim.list_extend(pieces, ci.waiting or {})
  return ' CI: ' .. table.concat(pieces, ' · ')
end

--- The panel's lines, and what each line stands for
---@param session DyReviewSession
---@return string[] lines
---@return table<integer, DyReviewPanelRow> rows By line number
function M.render(session)
  local ai = pending_ai(session.state.drafts)
  local done, changed, ai_total, width = 0, 0, 0, 0
  for _, file in ipairs(session.files) do
    local mark = M.mark(session, file)
    if mark == '✓' then done = done + 1 end
    if mark == '⟳' then changed = changed + 1 end
    width = math.max(width, vim.fn.strdisplaywidth(file.path))
  end
  for _, n in pairs(ai) do
    ai_total = ai_total + n
  end
  width = math.min(width, M.PATH_WIDTH) + 2

  local lines, rows = {}, {}
  local function add(line, row)
    lines[#lines + 1] = (line:gsub('%s+$', ''))
    rows[#lines] = row
  end

  add(
    (' PR !%s  %s   (%d of %d files reviewed)'):format(
      session.pull.id,
      session.pull.title,
      done,
      #session.files
    )
  )
  local ci_line = M.ci_line(session)
  if ci_line then add(ci_line, { ci = true }) end
  local summary = {}
  if ai_total > 0 then
    summary[#summary + 1] = ('AI: %s to look at'):format(
      count_of(ai_total, 'draft')
    )
  end
  if changed > 0 then
    summary[#summary + 1] = ('⟳ %s changed since last review'):format(
      count_of(changed, 'file')
    )
  end
  if #summary > 0 then add(' ' .. table.concat(summary, '   ')) end
  if session.ai_summary then
    local text = wrap(session.ai_summary, M.WIDTH - 4)
    if #text > M.SUMMARY_LINES then
      text = vim.list_slice(text, 1, M.SUMMARY_LINES - 1)
      text[#text + 1] = '…'
    end
    add(' AI summary:')
    for _, line in ipairs(text) do
      add('   ' .. line)
    end
  end
  if session.blocked then add(' Read only: ' .. session.blocked) end
  if session.threads_error then
    add(' Threads not read: ' .. session.threads_error)
  end
  if not session.trusted then
    add(' Diff only: no language server runs until `:DyReview trust`')
  end

  for _, bucket in ipairs(session.buckets) do
    local closed = folded(session, bucket.kind)
    local n = #bucket.files
    add(
      (' %s %-18s%2d %-5s  %s%s'):format(
        closed and '▸' or '▾',
        M.LABELS[bucket.kind] or bucket.kind,
        n,
        n == 1 and 'file' or 'files',
        counts(bucket.added, bucket.removed),
        (closed and bucket.kind == 'generated') and '   (collapsed)' or ''
      ),
      { kind = bucket.kind }
    )
    if not closed then
      for _, file in ipairs(bucket.files) do
        local n_ai = ai[file.path]
        add(
          ('   %s %s %s%s%s'):format(
            file.risk > 0 and '!' or ' ',
            M.mark(session, file),
            pad(file.path, width),
            counts(file.added, file.removed, file.binary),
            n_ai and ('   %d AI'):format(n_ai) or ''
          ),
          { path = file.path }
        )
      end
    end
  end
  return lines, rows
end

--- Draw `session` into its panel buffer, if it has one
---@param session DyReviewSession
function M.refresh(session)
  local bufnr = session.panel_buf
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  local lines, rows = M.render(session)
  session.panel_rows = rows
  require('util.scratch').set(bufnr, lines)
end

--- The row under the cursor of the panel
---@param session DyReviewSession
---@return DyReviewPanelRow?
local function row_under_cursor(session)
  return (session.panel_rows or {})[vim.api.nvim_win_get_cursor(0)[1]]
end

--- Open the file under the cursor, fold or unfold its bucket, or list the
--- CI runs from the CI line
---@param session DyReviewSession
function M.select(session)
  local row = row_under_cursor(session)
  if not row then return end
  if row.ci then return require('tools.review.ci').pick(session) end
  if row.kind then
    session.collapsed = session.collapsed or {}
    session.collapsed[row.kind] = not folded(session, row.kind)
    return M.refresh(session)
  end
  require('tools.review').show(row.path)
end

--- The buffer of the panel, made the first time it is asked for
---@param session DyReviewSession
---@return integer
local function buffer(session)
  local bufnr = session.panel_buf
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then return bufnr end
  bufnr = vim.api.nvim_create_buf(false, true)
  session.panel_buf = bufnr
  vim.bo[bufnr].buftype = 'nofile'
  vim.bo[bufnr].bufhidden = 'hide'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].undofile = false
  vim.bo[bufnr].filetype = 'dyreview'
  local map = require('util.plugin').safe_keymap_set
  map('n', '<CR>', function() M.select(session) end, {
    buffer = bufnr,
    desc = 'Open File, Fold Bucket or List CI Runs',
  })
  map('n', 'r', function() require('tools.review.ci').load(session) end, {
    buffer = bufnr,
    desc = 'Refresh CI Status',
  })
  map('n', 'm', function()
    local row = row_under_cursor(session)
    if row and row.path then require('tools.review').mark(row.path) end
  end, { buffer = bufnr, desc = 'Mark File Reviewed' })
  map('n', 'q', '<cmd>close<cr>', {
    buffer = bufnr,
    desc = 'Close Panel',
    nowait = true,
  })
  return bufnr
end

--- Show the panel at the left of the current tab, unless it is there already
---@param session DyReviewSession
function M.open(session)
  local bufnr = buffer(session)
  M.refresh(session)
  local tab = vim.api.nvim_get_current_tabpage()
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_buf(win) == bufnr then return end
  end
  local current = vim.api.nvim_get_current_win()
  vim.cmd(('topleft vertical %dsplit'):format(M.WIDTH))
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, bufnr)
  vim.wo[win][0].winfixwidth = true
  vim.wo[win][0].number = false
  vim.wo[win][0].relativenumber = false
  vim.wo[win][0].signcolumn = 'no'
  vim.wo[win][0].wrap = false
  vim.wo[win][0].cursorline = true
  require('util.panel').setup(bufnr)
  if vim.api.nvim_win_is_valid(current) then
    vim.api.nvim_set_current_win(current)
  end
end

--- Put the panel's cursor on `path`
---@param session DyReviewSession
---@param path string
function M.follow(session, path)
  local bufnr = session.panel_buf
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then return end
  for line, row in pairs(session.panel_rows or {}) do
    if row.path == path then
      for _, win in ipairs(vim.fn.win_findbuf(bufnr)) do
        pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
      end
      return
    end
  end
end

--- Wipe the panel and every window showing it
---@param session DyReviewSession
function M.close(session)
  local bufnr = session.panel_buf
  session.panel_buf = nil
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
  end
end

return M
