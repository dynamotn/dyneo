--- GitLab merge requests for `:DyReview`, through `glab`
---
--- Everything but the listing comes from the REST API, under
--- `projects/<encoded path>/merge_requests`, a page at a time to the end or
--- to `M.MAX_PAGES`. The listing asks GraphQL, whose merge requests carry
--- their diff refs: REST lists them without, and one call per merge request
--- would be a burst. Every call goes through `util.forge`, so `glab` holds
--- the token and has a deadline.
---
--- A review is sent as draft notes, published together by `bulk_publish`.
--- GitLab publishes every draft note of the user on the merge request, made
--- here or on the web, so `pending` imports them all and `submit` checks,
--- before any write, that the draft notes on GitLab are exactly the imported
--- ones and those sent from here.
---
--- A draft is placed by the merge request's own diff (`/diffs`): GitLab
--- takes both lines of an unchanged one, the old and new path of a renamed
--- file, and a line code at each end of a range; a line in no hunk goes on
--- the file.
---
--- A draft sent goes by `draft:<draft note id>`. Publishing deletes the draft
--- note and answers no id for the note it becomes; a later submit that finds
--- the draft note gone looks for a note of mine with the same text in the
--- same thread or file, and tells the draft published when there is one and
--- lost when there is none.
---@class DyReviewGitLab: DyReviewForge
local M = {}

local forge = require('util.forge')

--- Pages read before a listing stops and says it was capped
M.MAX_PAGES = 20

--- Rows asked for per page, the most GitLab hands over
M.PER_PAGE = 100

--- Merge requests a branch is looked up among: forks may share its name
M.BRANCH_ROWS = 20

M.verdicts = {
  { id = 'approve', label = 'Approve' },
  { id = 'revoke', label = 'Revoke approval' },
  { id = 'comment', label = 'Comment' },
}

--- Whether I have approved, for each verdict that sets it
local APPROVED = { approve = true, revoke = false }

--- Why a review cannot be sent as the draft notes on GitLab stand
local CHANGED = 'the pending review on GitLab no longer matches the drafts '
  .. 'here; open the merge request again'

--- The signed-in user, by host, asked once a session
---@type table<string, { id: integer, username: string }>
local users = {}

--- `value` when it is a string, `default` otherwise (`null` and the like)
---@param value any
---@param default? string
---@return string?
local function text(value, default)
  return type(value) == 'string' and value or default
end

--- `value` when it is a whole number, nil otherwise
---@param value any
---@return integer?
local function int(value)
  return type(value) == 'number' and value == math.floor(value) and value or nil
end

--- `value` when it is a table, nil otherwise (`null` and the like)
---@param value any
---@return table?
local function tbl(value) return type(value) == 'table' and value or nil end

--- Why `remote` cannot be asked, or nil when it can
---@param remote DyForgeRemote
---@return string?
local function bad_remote(remote)
  local slug = remote.slug or ''
  if not slug:match('^[^/]+/.+[^/]$') or slug:find('//', 1, true) then
    return 'Not a GitLab project: ' .. tostring(remote.slug)
  end
end

--- `projects/<path>/merge_requests`, the path encoded whole: it comes from a
--- remote anyone can set, and must not bend the endpoint
---@param remote DyForgeRemote
---@return string
local function mrs_path(remote)
  return ('projects/%s/merge_requests'):format(forge.encode(remote.slug))
end

--- The iid of `pull`, nil when it is not one
---@param pull DyReviewPull
---@return string?
local function iid(pull)
  return type(pull.id) == 'string' and pull.id:match('^%d+$') or nil
end

--- The endpoint of merge request `pull`, with `rest` after it
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param rest? string
---@return string
local function mr_path(remote, pull, rest)
  return ('%s/%s%s'):format(mrs_path(remote), pull.id, rest or '')
end

--- Whether `ref` is a branch name that stays one inside a refspec
---@param ref string
---@return boolean
local function plain_ref(ref)
  return ref:match('^[%w._/-]+$') ~= nil
    and not ref:find('..', 1, true)
    and not ref:match('^[-/]')
    and not ref:match('/$')
end

--- A merge request of the REST API as `:DyReview` keeps it, nil when it
--- lacks what a review needs: diff refs come a moment after it is opened
---@param raw any
---@return DyReviewPull?
local function to_pull(raw)
  if type(raw) ~= 'table' or not int(raw.iid) then return nil end
  local refs = tbl(raw.diff_refs)
  if not refs or not (text(refs.base_sha) and text(refs.head_sha)) then
    return nil
  end
  if not text(raw.target_branch) then return nil end
  local n = raw.iid
  local fetch = {
    ('+refs/merge-requests/%d/head:refs/dyneo/review/gitlab-%d/head'):format(
      n,
      n
    ),
  }
  -- The base's commit may be newer than any local branch
  if plain_ref(raw.target_branch) then
    table.insert(
      fetch,
      ('+refs/heads/%s:refs/dyneo/review/gitlab-%d/base'):format(
        raw.target_branch,
        n
      )
    )
  end
  local read_only
  if raw.state ~= nil and raw.state ~= 'opened' then
    read_only = raw.state == 'merged' and 'The merge request is merged'
      or 'The merge request is closed'
  end
  local author = tbl(raw.author)
  return {
    id = tostring(n),
    title = text(raw.title, ''),
    -- A deleted account has no author
    author = author and text(author.username, 'ghost') or 'ghost',
    body = text(raw.description, ''),
    url = text(raw.web_url, ''),
    base_ref = raw.target_branch,
    head_ref = text(raw.source_branch, ''),
    base_sha = refs.base_sha,
    head_sha = refs.head_sha,
    start_sha = text(refs.start_sha),
    fetch = fetch,
    fork = raw.source_project_id ~= raw.target_project_id,
    read_only = read_only,
  }
end

--- Every row at `path`, a page at a time
---
--- A page that fails fails the whole listing; one that is full at
--- `M.MAX_PAGES` stops it, with `capped`.
---@param remote DyForgeRemote
---@param path string Without a query
---@param on_done fun(rows?: table[], err?: string, capped?: boolean)
local function pages(remote, path, on_done)
  local rows = {}
  local function page(index)
    local url = ('%s?per_page=%d&page=%d'):format(path, M.PER_PAGE, index)
    forge.api(remote, url, function(data, err)
      if data == nil then return on_done(nil, err) end
      if type(data) ~= 'table' or not vim.islist(data) then
        return on_done(nil, 'GitLab answered with something not a list')
      end
      vim.list_extend(rows, data)
      if #data < M.PER_PAGE then return on_done(rows, nil, false) end
      if index >= M.MAX_PAGES then return on_done(rows, nil, true) end
      page(index + 1)
    end)
  end
  page(1)
end

--- Every row at `path`, failing rather than handing over part of them
---@param remote DyForgeRemote
---@param path string
---@param what string What the rows are, for the error
---@param on_done fun(rows?: table[], err?: string)
local function all_pages(remote, path, what, on_done)
  pages(remote, path, function(rows, err, capped)
    if not rows then return on_done(nil, err) end
    if capped then
      return on_done(nil, ('More %s than can be read on GitLab'):format(what))
    end
    on_done(rows)
  end)
end

--- Hand `on_done` the user `glab` is signed in as on `remote`'s host
---@param remote DyForgeRemote
---@param on_done fun(user?: { id: integer, username: string }, err?: string)
local function whoami(remote, on_done)
  local known = users[remote.host]
  if known then return on_done(known) end
  forge.api(remote, 'user', function(data, err)
    local id = type(data) == 'table' and int(data.id)
    local name = type(data) == 'table' and text(data.username)
    if not (id and name) then
      return on_done(nil, err or 'GitLab did not say who is signed in')
    end
    -- Usernames match whatever their case
    users[remote.host] = { id = id, username = name:lower() }
    on_done(users[remote.host])
  end)
end

local LIST_QUERY = [[
query DyReviewMergeRequests($path: ID!, $cursor: String) {
  project(fullPath: $path) {
    mergeRequests(state: opened, first: 100, after: $cursor) {
      pageInfo { hasNextPage endCursor }
      nodes {
        iid title description webUrl state sourceBranch targetBranch
        sourceProjectId targetProjectId
        author { username }
        reviewers { nodes { username } }
        diffRefs { baseSha headSha startSha }
      }
    }
  }
}]]

--- Run a GraphQL `query` and hand `on_done` its `data`
---
--- Sent as a write, the only call that carries a body; GraphQL answers its
--- own errors next to the data, and any of them fails the call.
---@param remote DyForgeRemote
---@param query string
---@param variables table
---@param on_done fun(data?: table, err?: string)
local function graphql(remote, query, variables, on_done)
  forge.write(
    remote,
    'POST',
    'graphql',
    { query = query, variables = variables },
    function(answer, err)
      if answer == nil then return on_done(nil, err) end
      local errors = type(answer) == 'table' and answer.errors
      if type(errors) == 'table' and errors[1] ~= nil then
        local first = errors[1]
        return on_done(
          nil,
          'GitLab: '
            .. (
              type(first) == 'table' and text(first.message) or 'GraphQL error'
            )
        )
      end
      if type(answer) ~= 'table' or type(answer.data) ~= 'table' then
        return on_done(nil, 'GitLab answered with no data')
      end
      on_done(answer.data)
    end
  )
end

--- A merge request of GraphQL in the shape of the REST API
---@param node table
---@return table
local function from_graphql(node)
  local refs = tbl(node.diffRefs)
  local reviewers = tbl(node.reviewers) and tbl(node.reviewers.nodes) or {}
  return {
    iid = tonumber(text(node.iid, '')),
    title = node.title,
    description = node.description,
    web_url = node.webUrl,
    state = node.state,
    source_branch = node.sourceBranch,
    target_branch = node.targetBranch,
    source_project_id = node.sourceProjectId,
    target_project_id = node.targetProjectId,
    author = node.author,
    reviewers = reviewers,
    diff_refs = refs and {
      base_sha = refs.baseSha,
      head_sha = refs.headSha,
      start_sha = refs.startSha,
    },
  }
end

--- Open merge requests, and whether my review is asked on each
---
--- One whose diff GitLab has not worked out yet is left out: it cannot be
--- reviewed until it has.
---@param remote DyForgeRemote
---@param cb fun(pulls?: DyReviewPull[], err?: string, capped?: boolean)
function M.list(remote, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  whoami(remote, function(me, err)
    if not me then return cb(nil, err) end
    local pulls = {}
    local function page(index, cursor)
      graphql(
        remote,
        LIST_QUERY,
        { path = remote.slug, cursor = cursor },
        function(data, list_err)
          if not data then return cb(nil, list_err) end
          local project = tbl(data.project)
          local list = project and tbl(project.mergeRequests)
          if not list or type(list.nodes) ~= 'table' then
            return cb(nil, 'GitLab answered with no merge requests')
          end
          for _, node in ipairs(list.nodes) do
            local raw = type(node) == 'table' and from_graphql(node)
            if not raw or not raw.iid then
              return cb(nil, 'GitLab answered with a malformed merge request')
            end
            local pull = raw.diff_refs and to_pull(raw)
            if raw.diff_refs and not pull then
              return cb(nil, 'GitLab answered with a malformed merge request')
            end
            if pull then
              pull.requested = false
              for _, user in ipairs(raw.reviewers) do
                if
                  type(user) == 'table'
                  and text(user.username, ''):lower() == me.username
                then
                  pull.requested = true
                end
              end
              pulls[#pulls + 1] = pull
            end
          end
          local info = tbl(list.pageInfo) or {}
          if not info.hasNextPage then return cb(pulls, nil, false) end
          if index >= M.MAX_PAGES or not text(info.endCursor) then
            return cb(pulls, nil, true)
          end
          page(index + 1, info.endCursor)
        end
      )
    end
    page(1, nil)
  end)
end

--- Merge request `id`
---@param remote DyForgeRemote
---@param id string
---@param cb fun(pull?: DyReviewPull, err?: string)
function M.get(remote, id, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if type(id) ~= 'string' or not id:match('^%d+$') then
    return cb(nil, 'Not a merge request number: ' .. tostring(id))
  end
  forge.api(remote, ('%s/%s'):format(mrs_path(remote), id), function(data, err)
    if data == nil then return cb(nil, err) end
    local pull = to_pull(data)
    if not pull then
      return cb(
        nil,
        'GitLab answered with a merge request whose diff is not ready'
      )
    end
    cb(pull)
  end)
end

--- The open merge request of `branch` within the project, nil without an
--- error when it has none. One from a fork's branch of the same name is
--- someone else's.
---@param remote DyForgeRemote
---@param branch string
---@param cb fun(pull?: DyReviewPull, err?: string)
function M.for_branch(remote, branch, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  local path = ('%s?state=opened&source_branch=%s&per_page=%d'):format(
    mrs_path(remote),
    forge.encode(branch),
    M.BRANCH_ROWS
  )
  forge.api(remote, path, function(data, err)
    if data == nil then return cb(nil, err) end
    if type(data) ~= 'table' or not vim.islist(data) then
      return cb(nil, 'GitLab answered with something not a list')
    end
    for _, row in ipairs(data) do
      if
        type(row) == 'table'
        and int(row.iid)
        and row.source_project_id == row.target_project_id
      then
        -- The listing has no diff refs
        return M.get(remote, tostring(row.iid), cb)
      end
    end
    cb(nil)
  end)
end

--- The position of a note: path, side, line and the start of its range,
--- nil for a note on no diff
---@param position any
---@return { path: string, side: 'old'|'new', line?: integer, start_line?: integer, file: boolean }?
local function where(position)
  position = tbl(position)
  if not position then return nil end
  local path = text(position.new_path) or text(position.old_path)
  if not path then return nil end
  if position.position_type == 'file' then
    return { path = path, side = 'new', file = true }
  end
  local new, old = int(position.new_line), int(position.old_line)
  local side = (new or not old) and 'new' or 'old'
  local line = side == 'new' and new or old
  local at = { path = path, side = side, line = line, file = line == nil }
  local range = tbl(position.line_range)
  local start = range and tbl(range.start)
  if start and line then
    local first = side == 'new' and int(start.new_line) or int(start.old_line)
    if first and first < line then at.start_line = first end
  end
  return at
end

--- Every discussion of `pull`, each note in it
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(rows?: table[], err?: string, capped?: boolean)
local function discussions(remote, pull, on_done)
  pages(remote, mr_path(remote, pull, '/discussions'), on_done)
end

--- A discussion on the diff as `:DyReview` keeps it, nil for one on no diff
--- or a system note
---@param row any
---@return DyReviewThread?
local function to_thread(row)
  local notes = tbl(row) and tbl(row.notes)
  local first = notes and tbl(notes[1])
  if not first or first.system == true or not text(row.id) then return nil end
  local at = where(first.position)
  if not at then return nil end
  local thread = {
    id = row.id,
    path = at.path,
    side = at.side,
    line = at.line,
    start_line = at.start_line,
    resolved = first.resolved == true,
    comments = {},
  }
  ---@cast notes table
  for _, note in ipairs(notes) do
    if type(note) == 'table' and note.system ~= true then
      local author = tbl(note.author)
      table.insert(thread.comments, {
        -- A deleted account has no author
        author = author and text(author.username, 'ghost') or 'ghost',
        body = text(note.body, ''),
        time = text(note.created_at, ''),
      })
    end
  end
  return thread
end

--- Every thread on the diff of `pull`, with its comments
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param cb fun(threads?: DyReviewThread[], err?: string, capped?: boolean)
function M.threads(remote, pull, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if not iid(pull) then return cb(nil, 'Not a merge request number') end
  discussions(remote, pull, function(rows, err, capped)
    if not rows then return cb(nil, err) end
    local threads = {}
    for _, row in ipairs(rows) do
      local thread = to_thread(row)
      if thread then threads[#threads + 1] = thread end
    end
    cb(threads, nil, capped)
  end)
end

--- The id a draft imported from draft note `id` goes by, the same on every
--- import
---@param id any
---@return string
local function forge_draft_id(id)
  return vim.fn.sha256('gitlab:' .. tostring(id)):sub(1, 12)
end

--- My draft notes on `pull`, every one of them or an error
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(notes?: table[], err?: string)
local function draft_notes(remote, pull, on_done)
  all_pages(
    remote,
    mr_path(remote, pull, '/draft_notes'),
    'draft notes',
    function(rows, err)
      if not rows then return on_done(nil, err) end
      for _, note in ipairs(rows) do
        if type(note) ~= 'table' or not int(note.id) then
          return on_done(nil, 'GitLab answered with a malformed draft note')
        end
      end
      on_done(rows)
    end
  )
end

--- A draft note as a draft
---@param note table
---@return DyReviewDraft
local function to_draft(note)
  local draft = {
    id = forge_draft_id(note.id),
    origin = 'forge',
    state = 'ready',
    path = '',
    side = 'new',
    line = 1,
    body = text(note.note, ''),
  }
  if text(note.discussion_id) then
    draft.reply_to = note.discussion_id
    if note.resolve_discussion == true then draft.resolve = true end
    return draft
  end
  local at = where(note.position)
  if not at then
    -- A note on the merge request itself names no file
    draft.file_level = true
    return draft
  end
  draft.path, draft.side = at.path, at.side
  if at.file then
    -- The line a file-level note names is the one its text starts with
    draft.file_level = true
    draft.line = tonumber(draft.body:match('^L(%d+): ')) or 1
    return draft
  end
  draft.line, draft.start_line = at.line, at.start_line
  return draft
end

--- My draft notes on `pull`, as drafts from the forge
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param cb fun(drafts?: DyReviewDraft[], err?: string)
function M.pending(remote, pull, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if not iid(pull) then return cb(nil, 'Not a merge request number') end
  draft_notes(remote, pull, function(notes, err)
    if not notes then return cb(nil, err) end
    cb(vim.tbl_map(to_draft, notes))
  end)
end

--- A suggestion of `lines` replacing the line commented on and `above` lines
--- before it, fenced longer than any run of backticks it holds
---@param lines string[]
---@param above integer
---@return string
local function fenced(lines, above)
  local longest = 2
  for _, line in ipairs(lines) do
    for run in line:gmatch('`+') do
      longest = math.max(longest, #run)
    end
  end
  local fence = ('`'):rep(longest + 1)
  return ('%ssuggestion:-%d+0\n%s\n%s'):format(
    fence,
    above,
    table.concat(lines, '\n'),
    fence
  )
end

--- The start of a draft's range, nil for a single line
---@param draft DyReviewDraft
---@return integer?
local function range_start(draft)
  if draft.start_line and draft.start_line < draft.line then
    return draft.start_line
  end
end

--- The text a draft sends: its body, then its suggestion over every line
--- of its range, and for a file-level comment the line it is about first
---@param draft DyReviewDraft
---@return string
local function body_of(draft)
  local body = draft.body or ''
  if draft.suggestion then
    local start = range_start(draft)
    local block = fenced(draft.suggestion, start and draft.line - start or 0)
    body = body ~= '' and (body .. '\n\n' .. block) or block
  end
  if draft.file_level then body = ('L%d: %s'):format(draft.line, body) end
  return body
end

--- The text a draft was published with
---@param draft DyReviewDraft
---@return string
local function sent_text(draft)
  if draft.origin == 'forge' then return draft.body or '' end
  return body_of(draft)
end

--- The SHA-1 of `msg` in hex, as GitLab names a file in a line code
---@param msg string
---@return string
local function sha1(msg)
  local bit = require('bit')
  local band, bor, bxor, bnot = bit.band, bit.bor, bit.bxor, bit.bnot
  local rol, tobit, tohex = bit.rol, bit.tobit, bit.tohex
  local h = { 0x67452301, 0xEFCDAB89, 0x98BADCFE, 0x10325476, 0xC3D2E1F0 }
  local bits = #msg * 8
  local function be32(n)
    return string.char(
      math.floor(n / 2 ^ 24) % 256,
      math.floor(n / 2 ^ 16) % 256,
      math.floor(n / 2 ^ 8) % 256,
      n % 256
    )
  end
  msg = msg
    .. '\128'
    .. ('\0'):rep((55 - #msg) % 64)
    .. be32(math.floor(bits / 2 ^ 32))
    .. be32(bits % 2 ^ 32)
  local w = {}
  for chunk = 1, #msg, 64 do
    for i = 0, 15 do
      local a, b, c, d = msg:byte(chunk + i * 4, chunk + i * 4 + 3)
      w[i] = tobit(a * 2 ^ 24 + b * 2 ^ 16 + c * 2 ^ 8 + d)
    end
    for i = 16, 79 do
      w[i] = rol(bxor(w[i - 3], w[i - 8], w[i - 14], w[i - 16]), 1)
    end
    local a, b, c, d, e = h[1], h[2], h[3], h[4], h[5]
    for i = 0, 79 do
      local f, k
      if i < 20 then
        f, k = bor(band(b, c), band(bnot(b), d)), 0x5A827999
      elseif i < 40 then
        f, k = bxor(b, c, d), 0x6ED9EBA1
      elseif i < 60 then
        f, k = bor(band(b, c), band(b, d), band(c, d)), 0x8F1BBCDC
      else
        f, k = bxor(b, c, d), 0xCA62C1D6
      end
      local t = tobit(rol(a, 5) + f + e + k + w[i])
      a, b, c, d, e = t, a, rol(b, 30), c, d
    end
    h[1], h[2], h[3] = tobit(h[1] + a), tobit(h[2] + b), tobit(h[3] + c)
    h[4], h[5] = tobit(h[4] + d), tobit(h[5] + e)
  end
  return tohex(h[1]) .. tohex(h[2]) .. tohex(h[3]) .. tohex(h[4]) .. tohex(h[5])
end

---@class DyGitLabLine
---@field kind 'new'|'old'|'context' added, removed or unchanged
---@field old integer The line before the change, or the one it comes before
---@field new integer The line after the change, or the one it comes before

---@class DyGitLabFile
---@field old_path string
---@field new_path string
---@field new table<integer, DyGitLabLine> By line on the new side
---@field old table<integer, DyGitLabLine> By line on the old side

--- The lines of a file's unified diff, by side
---
--- An added line keeps the old line it comes before, and a removed one the
--- new line: GitLab's line codes name both.
---@param diff string
---@return table<integer, DyGitLabLine> new
---@return table<integer, DyGitLabLine> old
local function diff_lines(diff)
  local new, old = {}, {}
  local o, n
  for line in (diff .. '\n'):gmatch('([^\n]*)\n') do
    local from, to = line:match('^@@ %-(%d+),?%d* %+(%d+),?%d* @@')
    if from then
      o, n = tonumber(from), tonumber(to)
    elseif o and n then
      local mark = line:sub(1, 1)
      if mark == ' ' then
        local at = { kind = 'context', old = o, new = n }
        new[n], old[o] = at, at
        o, n = o + 1, n + 1
      elseif mark == '-' then
        old[o] = { kind = 'old', old = o, new = n }
        o = o + 1
      elseif mark == '+' then
        new[n] = { kind = 'new', old = o, new = n }
        n = n + 1
      end
    end
  end
  return new, old
end

--- The files of `pull`'s diff, by new and by old path
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(files?: table<string, DyGitLabFile>, err?: string)
local function diff_files(remote, pull, on_done)
  all_pages(
    remote,
    mr_path(remote, pull, '/diffs'),
    'changed files',
    function(rows, err)
      if not rows then return on_done(nil, err) end
      local files = {}
      for _, row in ipairs(rows) do
        local new_path = tbl(row) and text(row.new_path)
        local old_path = tbl(row) and text(row.old_path)
        if not (new_path and old_path) then
          return on_done(nil, 'GitLab answered with a malformed diff')
        end
        local new, old = diff_lines(text(row.diff, '') --[[@as string]])
        local file =
          { old_path = old_path, new_path = new_path, new = new, old = old }
        files[old_path] = files[old_path] or file
        -- The new path wins: it is the one a draft names
        files[new_path] = file
      end
      on_done(files)
    end
  )
end

--- A line of `file` as an end of a `line_range`
---@param file DyGitLabFile
---@param at DyGitLabLine
---@return table
local function range_end(file, at)
  return {
    line_code = ('%s_%d_%d'):format(sha1(file.new_path), at.old, at.new),
    -- GitLab's word for any line not added
    type = at.kind == 'new' and 'new' or 'old',
    old_line = at.kind ~= 'new' and at.old or nil,
    new_line = at.kind ~= 'old' and at.new or nil,
  }
end

--- A draft as the input of a new draft note on `pull`, placed by the merge
--- request's own diff, or why it cannot be
---
--- An unchanged line names both sides, an added or removed one its own side
--- only; a line in no hunk is a comment on the file naming the line.
---@param pull DyReviewPull
---@param files table<string, DyGitLabFile>
---@param draft DyReviewDraft
---@return table? input
---@return string? err
local function draft_note_input(pull, files, draft)
  if draft.reply_to then
    local input = {
      note = body_of(draft),
      in_reply_to_discussion_id = draft.reply_to,
    }
    if draft.resolve then input.resolve_discussion = true end
    return input
  end
  local file = files[draft.path]
  if not file then
    return nil, ("%s is not in the merge request's diff"):format(draft.path)
  end
  ---@type table<string, any>
  local position = {
    base_sha = pull.base_sha,
    start_sha = pull.start_sha or pull.base_sha,
    head_sha = pull.head_sha,
    old_path = file.old_path,
    new_path = file.new_path,
  }
  local lines = draft.side == 'old' and file.old or file.new
  local at = not draft.file_level and lines[draft.line]
  if not at then
    position.position_type = 'file'
    local on_file = vim.tbl_extend('force', draft, { file_level = true })
    return { note = body_of(on_file), position = position }
  end
  position.position_type = 'text'
  position.old_line = at.kind ~= 'new' and at.old or nil
  position.new_line = at.kind ~= 'old' and at.new or nil
  local start = range_start(draft)
  local first = start and lines[start]
  if first then
    position.line_range = {
      start = range_end(file, first),
      ['end'] = range_end(file, at),
    }
  end
  return { note = body_of(draft), position = position }
end

--- Run `worker` on each of `items` in turn, stopping at the first error
---@generic T
---@param items T[]
---@param worker fun(item: T, next: fun(err?: string))
---@param on_done fun(err?: string)
local function in_turn(items, worker, on_done)
  local function step(index)
    if index > #items then return on_done(nil) end
    worker(items[index], function(err)
      if err then return on_done(err) end
      step(index + 1)
    end)
  end
  step(1)
end

--- The forge id of draft note `id`
---@param id integer
---@return string
local function posted_id(id) return ('draft:%d'):format(id) end

--- The draft note a forge id `posted_id` made names, nil for another
---@param posted any
---@return integer?
local function parse_posted(posted)
  if type(posted) ~= 'string' then return nil end
  return tonumber(posted:match('^draft:(%d+)$'))
end

--- The id `pending` gives the draft note a forge id `posted` names, nil
--- for a forge id naming none
---@param posted string
---@return string?
function M.import_id(posted)
  local note = parse_posted(posted)
  return note and forge_draft_id(note) or nil
end

--- The note of mine in `rows` each draft was published as, by draft id
---
--- A note matches by its text and its place: the thread a reply went into,
--- the file a comment is on, or no file for a note on the merge request
--- itself. Each note stands for one draft only.
---@param rows table[] Every discussion
---@param me { id: integer }
---@param drafts DyReviewDraft[]
---@return table<string, integer> note_of Note id by draft id
local function published(rows, me, drafts)
  local note_of, taken = {}, {}
  for _, draft in ipairs(drafts) do
    local body = sent_text(draft)
    -- A line in no hunk went out on the file, naming the line
    local on_file = ('L%d: %s'):format(draft.line or 0, body)
    for _, row in ipairs(rows) do
      local notes = tbl(row) and tbl(row.notes) or {}
      for _, note in ipairs(notes) do
        local author = tbl(note) and tbl(note.author)
        local id = tbl(note) and int(note.id)
        local at = id and where(note.position)
        if
          id
          and not taken[id]
          and author
          and author.id == me.id
          and (note.body == body or not draft.file_level and note.body == on_file)
          and (
            draft.reply_to and row.id == draft.reply_to
            or not draft.reply_to and at and at.path == draft.path
            -- A draft note on the merge request itself names no file
            or not draft.reply_to and not at and draft.path == ''
          )
        then
          note_of[draft.id], taken[id] = id, true
          break
        end
      end
      if note_of[draft.id] then break end
    end
  end
  return note_of
end

--- A note of mine on the merge request itself holding `body`, nil for none
---
--- Only a note past `since`, the mark of the last whole submit, counts: the
--- same words said in an earlier round are no sign this round's went out.
---@param rows table[] Every discussion
---@param me { id: integer }
---@param body string
---@param since? integer
---@return integer?
local function body_note(rows, me, body, since)
  for _, row in ipairs(rows) do
    local notes = tbl(row) and tbl(row.notes) or {}
    for _, note in ipairs(notes) do
      local author = tbl(note) and tbl(note.author)
      if
        author
        and author.id == me.id
        and int(note.id)
        and note.id > (since or -1)
        and not tbl(note.position)
        and note.system ~= true
        and note.body == body
      then
        return note.id
      end
    end
  end
end

--- Whether I have approved `pull`
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(approved?: boolean, err?: string)
local function approved(remote, pull, on_done)
  forge.api(remote, mr_path(remote, pull, '/approvals'), function(data, err)
    if data == nil then return on_done(nil, err) end
    if type(data) ~= 'table' or type(data.user_has_approved) ~= 'boolean' then
      return on_done(nil, 'GitLab did not say whether you approved')
    end
    on_done(data.user_has_approved)
  end)
end

---@class DyReviewGitLabSend
---@field new DyReviewDraft[]       comments and replies, each a draft note
---@field resolves DyReviewDraft[]  threads resolved with no reply
---@field imported DyReviewDraft[]  imported, published with the rest
---@field note_of table<string, integer> Draft note by imported draft id
---@field publish boolean           draft notes wait on GitLab
---@field body? string              a note on the merge request
---@field verdict string
---@field approved? boolean         whether I have approved, when known
---@field mark? integer             the newest note id seen or posted

--- Send a checked review of `pull`: each new draft note, reported once it is
--- on GitLab, then every draft note published, the resolutions, the body as
--- a note, and the verdict last
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param plan DyReviewGitLabSend
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param on_done fun(err?: string)
local function send(remote, pull, plan, progress, on_done)
  ---@type table<DyReviewDraft, table>
  local inputs = {}
  local function add(draft, next)
    forge.write(
      remote,
      'POST',
      mr_path(remote, pull, '/draft_notes'),
      inputs[draft],
      function(data, err)
        if data == nil then return next(err) end
        local id = type(data) == 'table' and int(data.id)
        if not id then return next('GitLab created no draft note') end
        progress(draft, posted_id(id))
        next()
      end
    )
  end
  local function publish(next)
    if not (plan.publish or #plan.new > 0 or #plan.imported > 0) then
      return next()
    end
    forge.write(
      remote,
      'POST',
      mr_path(remote, pull, '/draft_notes/bulk_publish'),
      nil,
      function(data, err)
        if data == nil then return next(err) end
        for _, draft in ipairs(plan.imported) do
          progress(draft, posted_id(plan.note_of[draft.id]))
        end
        next()
      end
    )
  end
  local function resolve(draft, next)
    forge.write(
      remote,
      'PUT',
      mr_path(
        remote,
        pull,
        ('/discussions/%s?resolved=true'):format(forge.encode(draft.reply_to))
      ),
      nil,
      function(data, err)
        if data == nil then return next(err) end
        progress(draft, draft.reply_to)
        next()
      end
    )
  end
  local function note(next)
    if not plan.body or plan.body == '' then return next() end
    forge.write(
      remote,
      'POST',
      mr_path(remote, pull, '/notes'),
      { body = plan.body },
      function(data, err)
        local id = type(data) == 'table' and int(data.id)
        if id and id > (plan.mark or -1) then plan.mark = id end
        next(data == nil and err or nil)
      end
    )
  end
  local function verdict(next)
    local want = APPROVED[plan.verdict]
    if want == nil then return next() end
    local function set(now)
      if now == want then return next() end
      forge.write(
        remote,
        'POST',
        mr_path(remote, pull, want and '/approve' or '/unapprove'),
        -- GitLab refuses an approval of a head other than the one reviewed
        want and { sha = pull.head_sha } or nil,
        function(data, err) next(data == nil and err or nil) end
      )
    end
    if plan.approved ~= nil then return set(plan.approved) end
    approved(remote, pull, function(now, err)
      if now == nil then return next(err) end
      set(now)
    end)
  end
  local function write_all()
    in_turn(plan.new, add, function(add_err)
      if add_err then return on_done(add_err) end
      publish(function(publish_err)
        if publish_err then return on_done(publish_err) end
        in_turn(plan.resolves, resolve, function(resolve_err)
          if resolve_err then return on_done(resolve_err) end
          note(function(note_err)
            if note_err then return on_done(note_err) end
            verdict(on_done)
          end)
        end)
      end)
    end)
  end
  --- Every draft note's input, built before the first write: a draft that
  --- cannot be placed stops the submit while nothing is sent
  ---@param files table<string, DyGitLabFile>
  local function place(files)
    for _, draft in ipairs(plan.new) do
      local input, err = draft_note_input(pull, files, draft)
      if not input then return on_done(err) end
      inputs[draft] = input
    end
    write_all()
  end
  local on_diff = vim.tbl_filter(
    function(draft) return not draft.reply_to end,
    plan.new
  )
  if #on_diff == 0 then return place({}) end
  diff_files(remote, pull, function(files, err)
    if not files then return on_done(err) end
    place(files)
  end)
end

--- Send `drafts` with `review`'s verdict and text
---
--- Each new draft becomes a draft note, reported through `progress` as soon
--- as GitLab has it, so a submit cut short and run again never adds it
--- twice; a draft already `posted` is never sent. Once every one is in, all
--- my draft notes are published together, empty threads resolved, a body
--- posted as a note of its own (GitLab has no review text), and the
--- approval given or taken back last. A failed call stops the submit there
--- and is never tried again here: one that timed out may still have reached
--- GitLab.
---
--- Refused before any write: draft notes on GitLab other than the imported
--- ones and those sent from here, or an imported one gone, since publishing
--- sends them all; and drafts whose draft note was deleted unpublished,
--- named in `info.lost`, which only the caller may send again. With nothing
--- new, the threads are only resolved when the review asked for is already
--- out (`info.already`, the newest note of it, or the merge request when it
--- is the approval alone) or would be an empty comment (`info.skipped`).
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param drafts DyReviewDraft[]
---@param review { verdict: string, body?: string, since?: integer }
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param cb fun(err?: string, info?: { lost?: string[], already?: integer, skipped?: string, mark?: integer })
function M.submit(remote, pull, drafts, review, progress, cb)
  local verdict = type(review) == 'table' and review.verdict
  local known = false
  for _, v in ipairs(M.verdicts) do
    if v.id == verdict then known = true end
  end
  if not known then return cb('GitLab has no verdict ' .. tostring(verdict)) end
  ---@cast verdict string
  local bad = bad_remote(remote)
  if bad then return cb(bad) end
  if not iid(pull) then return cb('Not a merge request number') end
  ---@type DyReviewGitLabSend
  local plan = {
    new = {},
    resolves = {},
    imported = {},
    note_of = {},
    publish = false,
    body = review.body,
    verdict = verdict,
  }
  local answer = cb
  -- A whole submit says the newest note it knows of, the mark a later
  -- round's body is matched past
  cb = function(err, info)
    if err or not plan.mark then return answer(err, info) end
    answer(nil, vim.tbl_extend('force', info or {}, { mark = plan.mark }))
  end
  local sent = {}
  for _, draft in ipairs(drafts) do
    local note = parse_posted(draft.posted)
    if note then
      sent[#sent + 1] = { draft = draft, note = note }
    elseif not draft.posted then
      if draft.origin == 'forge' then
        table.insert(plan.imported, draft)
      elseif draft.reply_to and body_of(draft) == '' then
        if draft.resolve then table.insert(plan.resolves, draft) end
      else
        table.insert(plan.new, draft)
      end
    end
  end
  ---@param info table
  local function resolve_only(info)
    plan.new, plan.imported, plan.publish = {}, {}, false
    plan.body, plan.verdict = nil, 'comment'
    send(remote, pull, plan, progress, function(err)
      if err then return cb(err) end
      cb(nil, info)
    end)
  end
  whoami(remote, function(me, me_err)
    if not me then return cb(me_err) end
    draft_notes(remote, pull, function(notes, notes_err)
      if not notes then return cb(notes_err) end
      local on_forge = {}
      for _, note in ipairs(notes) do
        on_forge[note.id] = true
      end
      local imported_note = {}
      for _, note in ipairs(notes) do
        imported_note[forge_draft_id(note.id)] = note.id
      end
      local accounted = {}
      for _, draft in ipairs(plan.imported) do
        local note = imported_note[draft.id]
        if not note then return cb(CHANGED) end
        plan.note_of[draft.id], accounted[note] = note, true
      end
      local gone = {}
      for _, item in ipairs(sent) do
        if on_forge[item.note] then
          accounted[item.note], plan.publish = true, true
        else
          gone[#gone + 1] = item.draft
        end
      end
      for _, note in ipairs(notes) do
        if not accounted[note.id] then return cb(CHANGED) end
      end
      local nothing_new = #plan.new == 0
        and #plan.imported == 0
        and not plan.publish
      if #gone == 0 and not nothing_new then
        return send(remote, pull, plan, progress, cb)
      end
      discussions(remote, pull, function(rows, list_err, capped)
        if not rows then return cb(list_err) end
        -- A draft on a page never read would read as lost
        if capped then
          return cb('More discussions than can be read on GitLab')
        end
        for _, row in ipairs(rows) do
          for _, note in ipairs(tbl(row) and tbl(row.notes) or {}) do
            local id = tbl(note) and int(note.id)
            if id and id > (plan.mark or -1) then plan.mark = id end
          end
        end
        local note_of = published(rows, me, gone)
        local lost, newest = {}, nil
        for _, draft in ipairs(gone) do
          local note = note_of[draft.id]
          if not note then
            lost[#lost + 1] = draft.id
          elseif not newest or note > newest then
            newest = note
          end
        end
        if #lost > 0 then
          return cb(
            #lost == 1
                and '1 draft was deleted on GitLab before it was published'
              or ('%d drafts were deleted on GitLab before they were published'):format(
                #lost
              ),
            { lost = lost }
          )
        end
        if not nothing_new then
          return send(remote, pull, plan, progress, cb)
        end
        local has_body = review.body ~= nil and review.body ~= ''
        local body_out = has_body
          and body_note(rows, me, review.body, review.since)
        if body_out then
          -- A submit that timed out after the note went out
          plan.body = nil
          if not newest or body_out > newest then newest = body_out end
        end
        local function decide(now)
          local want = APPROVED[verdict]
          local holds = want == nil or now == want
          plan.approved = now
          if holds and (not has_body or body_out) then
            if want ~= nil or newest then
              return resolve_only({ already = newest or tonumber(pull.id) })
            end
            return resolve_only({ skipped = 'empty comment review' })
          end
          send(remote, pull, plan, progress, cb)
        end
        if APPROVED[verdict] == nil then return decide(nil) end
        approved(remote, pull, function(now, err)
          if now == nil then return cb(err) end
          decide(now)
        end)
      end)
    end)
  end)
end

--- GitLab's suggested change of the line commented on
---@param lines string[]
---@return string
function M.suggestion(lines) return fenced(lines, 0) end

return M
