--- The AI pass of a review: a summary, a reading order and draft comments
---
--- The pull request's title, description and diff go to the headless command
--- of `util.ai_policy` through `tools.ai.headless`, which checks the text and
--- the paths it came from before anything leaves. Generated and binary files
--- are left out and named. A diff larger than `tools.ai.git.MAX_DIFF` is
--- split by file into chunks, run two at a time; a chunk that fails is named
--- and the others are kept. The comments land as pending AI drafts: nothing
--- is sent to the forge until the reviewer keeps or edits them. Notices give
--- counts and paths, never the diff or the answer.
local M = {}

local drafts = require('tools.review.drafts')
local git = require('tools.review.git')
local session = require('tools.review.session')

local notify = require('util.notify').titled('Review AI')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- The prompt, under `prompts/` of this configuration or of the project's
--- trusted `.nvim` folder
M.PROMPT = 'review/pr.md'

--- Chunks sent at a time
M.CONCURRENCY = 2

--- Bytes of diff read for the whole pass; a file past it is left out
M.MAX_TOTAL = git.MAX_DIFF_BYTES

--- Paths named in one notice before the rest are counted
M.NAMED = 5

--- What the prompt asks a comment's severity to be
M.SEVERITIES =
  { blocker = true, suggestion = true, question = true, nit = true }

---@class DyReviewChunk
---@field paths string[] Files whose diff it holds
---@field old_paths string[] Where its renamed files were
---@field renamed table<string, string> New path of each old one
---@field text string
---@field cut? boolean Its one file's diff was cut to fit
---@field last? table<string, { old: integer, new: integer }> Of the cut
--- file, the last line of each side that was sent

---@class DyReviewParseOpts
---@field renamed? table<string, string> New path of each old one
---@field ignore? table<string, boolean> Paths whose comments are let go
--- uncounted

---@class DyReviewLeftOut
---@field path string
---@field why 'generated'|'binary'|'too large'

---@class DyReviewAiResult
---@field summary? string
---@field order? string[]
---@field drafts DyReviewDraft[] Without id, origin and state
---@field outside integer Comments dropped for lying outside the diff

--- The review a pass is under way for
---@type DyReviewSession?
local running

--- `path` as git writes it: no leading `./`, forward slashes
---@param path string
---@return string
function M.normalize(path)
  path = vim.trim(path):gsub('\\', '/')
  while path:sub(1, 2) == './' do
    path = path:sub(3)
  end
  return path
end

--- Why `file` is not sent, or nil
---@param file DyReviewFile
---@return 'generated'|'binary'|nil
local function excluded(file)
  if file.kind == 'generated' then return 'generated' end
  if file.binary then return 'binary' end
end

--- `text` cut to at most `max` bytes, at the end of a line where one fits
---@param text string
---@param max integer
---@return string
local function cut_to(text, max)
  local head = text:sub(1, max)
  local last = head:match('.*()\n')
  if last then return head:sub(1, last) end
  -- Never in the middle of a character
  return text:sub(1, max + vim.str_utf_start(text, max + 1))
end

--- The last line of each side that `text`, the diff of one file, shows
---@param text string
---@return { old: integer, new: integer }
function M.last_lines(text)
  local last = { old = 0, new = 0 }
  local old, new ---@type integer?, integer?
  for line in vim.gsplit(text, '\n', { plain = true }) do
    local o, n = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if o then
      old, new = tonumber(o), tonumber(n)
    elseif old and new then
      local c = line:sub(1, 1)
      if c == ' ' then
        last.old, last.new = old, new
        old, new = old + 1, new + 1
      elseif c == '-' then
        last.old = old
        old = old + 1
      elseif c == '+' then
        last.new = new
        new = new + 1
      end
    end
  end
  return last
end

--- Split the diffs of `files` into chunks of at most `max` bytes, by file and
--- in file order; one file larger than `max` is a chunk of its own, cut
---@param files DyReviewFile[]
---@param diffs table<string, string> By path
---@param max integer
---@return DyReviewChunk[] chunks
---@return DyReviewLeftOut[] left Generated, binary or missing from `diffs`
function M.chunks(files, diffs, max)
  local chunks, left = {}, {}
  ---@type DyReviewChunk?
  local current
  for _, file in ipairs(files) do
    local why = excluded(file)
    local text = diffs[file.path]
    if why then
      left[#left + 1] = { path = file.path, why = why }
    elseif not text then
      left[#left + 1] = { path = file.path, why = 'too large' }
    elseif text ~= '' then
      local cut ---@type { old: integer, new: integer }?
      if #text > max then
        text = cut_to(text, max)
        -- A comment past what was sent is about lines the AI never saw
        cut = M.last_lines(text)
        text = text
          .. ('\n(diff of %s cut at %d KiB)\n'):format(
            file.path,
            math.max(1, math.floor(max / 1024))
          )
      end
      if cut or not current or #current.text + #text > max then
        current = { paths = {}, old_paths = {}, renamed = {}, text = '' }
        chunks[#chunks + 1] = current
      end
      current.paths[#current.paths + 1] = file.path
      if file.old_path and file.old_path ~= file.path then
        current.old_paths[#current.old_paths + 1] = file.old_path
        current.renamed[file.old_path] = file.path
      end
      current.text = current.text .. text
      if cut then
        current.cut = true
        current.last = { [file.path] = cut }
        -- Nothing joins a cut file
        current = nil
      end
    end
  end
  return chunks, left
end

--- The first balanced JSON object in `text` holding a review, decoded
---@param text string
---@return table?
local function first_object(text)
  local start, tries = 1, 0
  while tries < 50 do
    local open = text:find('{', start, true)
    if not open then return nil end
    tries = tries + 1
    local depth, in_string, escaped, close = 0, false, false, nil
    for i = open, #text do
      local c = text:sub(i, i)
      if in_string then
        if escaped then
          escaped = false
        elseif c == '\\' then
          escaped = true
        elseif c == '"' then
          in_string = false
        end
      elseif c == '"' then
        in_string = true
      elseif c == '{' then
        depth = depth + 1
      elseif c == '}' then
        depth = depth - 1
        if depth == 0 then
          close = i
          break
        end
      end
    end
    if not close then
      -- A brace of prose that never closes: try the next one
      start = open + 1
    else
      local ok, value = pcall(
        vim.json.decode,
        text:sub(open, close),
        { luanil = { object = true, array = true } }
      )
      if
        ok
        and type(value) == 'table'
        and (
          value.summary ~= nil
          or value.order ~= nil
          or value.comments ~= nil
        )
      then
        return value
      end
      start = close + 1
    end
  end
end

--- A whole number from `value`, or nil
---@param value any
---@return integer?
local function whole(value)
  local n = tonumber(value)
  if not n or n < 1 then return nil end
  return math.floor(n)
end

--- `path` matched to a file of `hunks`: a `a/` or `b/` prefix of git's let
--- go, the old path of a renamed file taken for its new one
---@param path string
---@param hunks table<string, DyReviewHunks>
---@param renamed table<string, string>
---@return string
local function known_path(path, hunks, renamed)
  path = M.normalize(path)
  if hunks[path] then return path end
  local bare = path:match('^[ab]/(.+)$')
  for _, candidate in ipairs({ path, bare }) do
    if hunks[candidate] then return candidate end
    local new = renamed[candidate]
    if new and hunks[new] then return new end
  end
  return path
end

--- The draft of one comment of the answer, or nil when it does not read
---@param comment any
---@param hunks table<string, DyReviewHunks>
---@param opts DyReviewParseOpts
---@return DyReviewDraft? draft
---@return boolean outside Whether it pointed outside the diff
local function to_draft(comment, hunks, opts)
  if type(comment) ~= 'table' then return nil, false end
  local body = type(comment.body) == 'string' and vim.trim(comment.body) or ''
  local line = whole(comment.line)
  if type(comment.path) ~= 'string' or body == '' or not line then
    return nil, false
  end
  local path = known_path(comment.path, hunks, opts.renamed or {})
  if (opts.ignore or {})[path] then return nil, false end
  local side = comment.side == 'old' and 'old' or 'new'
  local start_line = whole(comment.start_line)
  if start_line and start_line > line then
    start_line, line = line, start_line
  end
  if start_line == line then start_line = nil end
  if
    not (hunks[path] and drafts.in_hunk(hunks[path], side, line, start_line))
  then
    return nil, true
  end
  local draft = {
    path = path,
    side = side,
    line = line,
    start_line = start_line,
    severity = M.SEVERITIES[comment.severity] and comment.severity
      or 'suggestion',
    body = body,
  }
  -- Its id, origin and state are given by `drafts.replace_ai`
  ---@cast draft DyReviewDraft
  -- A suggestion replaces lines of the new side; on the old one it means
  -- nothing
  if side == 'new' then
    if type(comment.suggestion) == 'string' then
      draft.suggestion =
        vim.split(comment.suggestion:gsub('\n$', ''), '\n', { plain = true })
    elseif
      type(comment.suggestion) == 'table'
      and vim.islist(comment.suggestion)
    then
      draft.suggestion = vim.tbl_filter(
        function(l) return type(l) == 'string' end,
        comment.suggestion
      )
    end
  end
  return draft, false
end

--- Read the AI's answer: the first JSON object in it, its comments made
--- drafts, those outside the diff counted and dropped
---
--- `hunks` holds only the files the AI was shown, so a comment on any other
--- file is outside.
---@param answer string
---@param hunks table<string, DyReviewHunks> By path
---@param opts? DyReviewParseOpts
---@return DyReviewAiResult? result
---@return string? err
function M.parse(answer, hunks, opts)
  opts = opts or {}
  local value = first_object(answer)
  if not value then return nil, 'the answer holds no JSON review' end
  if value.comments ~= nil and not vim.islist(value.comments) then
    return nil, 'the comments of the answer are not a list'
  end
  ---@type DyReviewAiResult
  local result = { drafts = {}, outside = 0 }
  if type(value.summary) == 'string' and vim.trim(value.summary) ~= '' then
    result.summary = vim.trim(value.summary)
  end
  if type(value.order) == 'table' and vim.islist(value.order) then
    result.order = {}
    for _, path in ipairs(value.order) do
      if type(path) == 'string' then
        result.order[#result.order + 1] =
          known_path(path, hunks, opts.renamed or {})
      end
    end
  end
  for _, comment in ipairs(value.comments or {}) do
    local draft, outside = to_draft(comment, hunks, opts)
    if draft then
      result.drafts[#result.drafts + 1] = draft
    elseif outside then
      result.outside = result.outside + 1
    end
  end
  return result
end

--- `paths` for a notice: the first `M.NAMED`, then how many more
---@param paths string[]
---@return string
local function names(paths)
  local shown = vim.list_slice(paths, 1, M.NAMED)
  local text = table.concat(shown, ', ')
  if #paths > #shown then
    text = text .. (' and %d more'):format(#paths - #shown)
  end
  return text
end

--- `n` and `word`, made plural unless `n` is one
---@param n integer
---@param word string
---@return string
local function count_of(n, word)
  return ('%d %s%s'):format(n, word, n == 1 and '' or 's')
end

--- The prompt for chunk `i` of `n`
---@param prompt DyAiPrompt
---@param s DyReviewSession
---@param chunk DyReviewChunk
---@param i integer
---@param n integer
---@return string
function M.build(prompt, s, chunk, i, n)
  local prompts = require('tools.ai.prompts')
  local description = vim.trim(s.pull.body or '')
  local values = {
    title = s.pull.title or '',
    part = ('%d of %d'):format(i, n),
    description = description ~= '' and description or '(none)',
    dfence = prompts.fence(description),
    files = table.concat(chunk.paths, '\n'),
    diff = chunk.text,
    fence = prompts.fence(chunk.text),
  }
  return (prompt.body:gsub('{(%a+)}', values))
end

--- `order` mapped to the paths of `files`, both sides normalized
---@param files DyReviewFile[]
---@param order string[]
---@return string[]
local function match_order(files, order)
  local by_norm = {}
  for _, file in ipairs(files) do
    by_norm[M.normalize(file.path)] = file.path
  end
  local out = {}
  for _, path in ipairs(order) do
    local real = by_norm[M.normalize(path)]
    if real then out[#out + 1] = real end
  end
  return out
end

--- Hand the results of the chunks to the review
---@param s DyReviewSession
---@param chunks DyReviewChunk[]
---@param results table<integer, DyReviewAiResult>
---@param failed { paths: string[], why?: string }[]
local function finish(s, chunks, results, failed)
  running = nil
  if session.current() ~= s then
    return notify('The review closed: the AI drafts are not kept', WARN)
  end
  local failed_paths = {}
  for _, f in ipairs(failed) do
    vim.list_extend(failed_paths, f.paths)
  end
  if not next(results) then
    return notify(
      ('The AI pass failed for %s: the drafts are as they were'):format(
        names(failed_paths)
      ),
      ERROR
    )
  end
  local new, order, summaries, outside = {}, {}, {}, 0
  for i = 1, #chunks do
    local result = results[i]
    if result then
      vim.list_extend(new, result.drafts)
      vim.list_extend(order, result.order or {})
      summaries[#summaries + 1] = result.summary
      outside = outside + result.outside
    end
  end
  -- The pending drafts of a chunk that failed stay until a pass reads it
  local lost = {}
  for _, path in ipairs(failed_paths) do
    lost[path] = true
  end
  for _, draft in ipairs(s.state.drafts) do
    if
      draft.origin == 'ai'
      and draft.state == 'pending'
      and lost[draft.path]
    then
      new[#new + 1] = draft
    end
  end
  drafts.replace_ai(s.state, new, s.pull.head_sha)
  s.ai_summary = #summaries > 0 and table.concat(summaries, '\n\n') or nil
  s.ai_order = match_order(s.files, order)
  s.buckets = require('tools.review.triage').buckets(s.files, s.ai_order)
  session.changed(s)

  local parts = {}
  local count = 0
  for _, draft in ipairs(s.state.drafts) do
    if draft.origin == 'ai' and draft.state == 'pending' then
      count = count + 1
    end
  end
  parts[1] = ('AI: %s to look at'):format(count_of(count, 'draft'))
  if outside > 0 then
    parts[#parts + 1] = ('%s pointed outside the diff'):format(
      count_of(outside, 'AI comment')
    )
  end
  for _, f in ipairs(failed) do
    parts[#parts + 1] = ('failed for %s%s'):format(
      names(f.paths),
      f.why and (': ' .. f.why) or ''
    )
  end
  notify(table.concat(parts, '; '), #failed > 0 and WARN or nil)
end

--- `hunks` cut to `last`, the last line of each side that was sent
---@param hunks DyReviewHunks
---@param last { old: integer, new: integer }
---@return DyReviewHunks
local function clip(hunks, last)
  local out = { old = {}, new = {} }
  for _, side in ipairs({ 'old', 'new' }) do
    for _, range in ipairs(hunks[side] or {}) do
      if range[1] <= last[side] then
        table.insert(out[side], { range[1], math.min(range[2], last[side]) })
      end
    end
  end
  return out
end

--- The hunks of the files `chunk` shows, cut where its diff was, and the
--- paths of it whose hunks could not be read
---@param s DyReviewSession
---@param chunk DyReviewChunk
---@return table<string, DyReviewHunks> hunks
---@return string[] missing
local function chunk_hunks(s, chunk)
  local hunks, missing = {}, {}
  for _, path in ipairs(chunk.paths) do
    local found = s.hunks[path]
    if not found then
      missing[#missing + 1] = path
    else
      local last = chunk.last and chunk.last[path]
      hunks[path] = last and clip(found, last) or found
    end
  end
  return hunks, missing
end

--- Send chunks of `s` to the AI, two at a time, and keep what they answer
---@param s DyReviewSession
---@param prompt DyAiPrompt
---@param chunks DyReviewChunk[]
local function send(s, prompt, chunks)
  local results, failed = {}, {}
  local items = {}
  for i = 1, #chunks do
    items[i] = i
  end
  require('util.system').each(items, M.CONCURRENCY, function(i, done)
    local chunk = chunks[i]
    local hunks, missing = chunk_hunks(s, chunk)
    if #missing > 0 then
      failed[#failed + 1] =
        { paths = missing, why = 'its changed lines could not be read' }
      if #missing == #chunk.paths then return done() end
    end
    local paths = vim.list_extend(vim.deepcopy(chunk.paths), chunk.old_paths)
    local opts = { renamed = chunk.renamed, ignore = {} }
    for _, path in ipairs(missing) do
      opts.ignore[path] = true
    end
    require('tools.ai').headless(
      M.build(prompt, s, chunk, i, #chunks),
      s.root,
      ('review of !%s, part %d of %d'):format(s.pull.id, i, #chunks),
      function(answer)
        -- A raise must not hold the pass forever
        local ok, result, why = pcall(M.parse, answer, hunks, opts)
        if ok and result then
          results[i] = result
        else
          failed[#failed + 1] = {
            paths = chunk.paths,
            why = ok and why or 'its answer could not be read',
          }
        end
        done()
      end,
      {
        paths = paths,
        -- `headless` has said why
        on_fail = function()
          failed[#failed + 1] = { paths = chunk.paths }
          done()
        end,
      }
    )
  end, function() finish(s, chunks, results, failed) end)
end

--- Run the AI pass over review `s`, the open one unless given
---@param s? DyReviewSession
function M.run(s)
  s = s or session.need()
  if not s then return end
  if session.current() ~= s then return notify('The review is closed', WARN) end
  if running then return notify('The AI pass is running already', WARN) end
  local prompt = require('tools.ai.prompts').template(M.PROMPT)
  if not prompt then return notify('No prompt ' .. M.PROMPT, ERROR) end
  local entries = {}
  for _, file in ipairs(s.files) do
    if not excluded(file) then
      entries[#entries + 1] = { path = file.path, old_path = file.old_path }
    end
  end
  running = s
  git.diff(
    s.root,
    s.merge_base,
    s.pull.head_sha,
    entries,
    M.MAX_TOTAL,
    function(diffs, err)
      if not diffs then
        running = nil
        return notify('Could not read the diff: ' .. (err or '?'), ERROR)
      end
      local max = require('tools.ai.git').MAX_DIFF
      local chunks, left = M.chunks(s.files, diffs, max)
      if #left > 0 then
        local paths = vim.tbl_map(
          function(l) return ('%s (%s)'):format(l.path, l.why) end,
          left
        )
        notify('Left out of the AI pass: ' .. names(paths))
      end
      if #chunks == 0 then
        running = nil
        return notify('Nothing to send to the AI', WARN)
      end
      -- Comments are placed against the hunks of every file sent
      local need = {}
      for _, file in ipairs(s.files) do
        if diffs[file.path] and not s.hunks[file.path] then
          need[#need + 1] = file
        end
      end
      session.load_hunks(s, need, function() send(s, prompt, chunks) end)
    end
  )
end

return M
