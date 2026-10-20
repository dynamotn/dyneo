--- GitHub pull requests for `:DyReview`, through `gh`
---
--- Listings come from the REST API, a page at a time to the end or to
--- `M.MAX_PAGES`; review threads, and adding to or submitting a pending
--- review, from GraphQL, which alone knows them. Every call goes through
--- `util.forge`, so `gh` holds the token and has a deadline.
---@class DyReviewGitHub: DyReviewForge
local M = {}

local forge = require('util.forge')

--- Pages read before a listing stops and says it was capped
M.MAX_PAGES = 20

--- Rows asked for per page, the most GitHub hands over
M.PER_PAGE = 100

M.verdicts = {
  { id = 'approve', label = 'Approve' },
  { id = 'request_changes', label = 'Request changes' },
  { id = 'comment', label = 'Comment' },
}

--- The review event of each verdict
local EVENTS = {
  approve = 'APPROVE',
  request_changes = 'REQUEST_CHANGES',
  comment = 'COMMENT',
}

--- GitHub's name for each side of a diff
local SIDES = { old = 'LEFT', new = 'RIGHT' }

--- The signed-in login, by host, asked once a session
---@type table<string, string>
local logins = {}

--- The owner and name of `remote`'s repository
---@param remote DyForgeRemote
---@return string? owner
---@return string? name
local function repo(remote)
  return (remote.slug or ''):match('^([^/]+)/([^/]+)$')
end

--- `repos/<owner>/<name>`, each part encoded: the slug comes from a remote
--- anyone can set, and must not bend the path
---@param remote DyForgeRemote
---@return string?
local function repo_path(remote)
  local owner, name = repo(remote)
  if not (owner and name) then return nil end
  return ('repos/%s/%s'):format(forge.encode(owner), forge.encode(name))
end

--- Why `remote` cannot be asked, or nil when it can
---@param remote DyForgeRemote
---@return string?
local function bad_remote(remote)
  if not repo(remote) then
    return 'Not a GitHub repository: ' .. tostring(remote.slug)
  end
end

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

--- Whether `ref` is a branch name that stays one inside a refspec
---@param ref string
---@return boolean
local function plain_ref(ref)
  return ref:match('^[%w._/-]+$') ~= nil
    and not ref:find('..', 1, true)
    and not ref:match('^[-/]')
    and not ref:match('/$')
end

--- A pull request of the REST API as `:DyReview` keeps it, nil when it lacks
--- what a review needs
---@param raw any
---@return DyReviewPull?
local function to_pull(raw)
  if type(raw) ~= 'table' or not int(raw.number) then return nil end
  local base, head = raw.base, raw.head
  if type(base) ~= 'table' or type(head) ~= 'table' then return nil end
  if not (text(base.sha) and text(head.sha) and text(base.ref)) then
    return nil
  end
  local n = raw.number
  local fetch = {
    ('+refs/pull/%d/head:refs/dyneo/review/github-%d/head'):format(n, n),
  }
  -- The base's commit may be newer than any local branch
  if plain_ref(base.ref) then
    table.insert(
      fetch,
      ('+refs/heads/%s:refs/dyneo/review/github-%d/base'):format(base.ref, n)
    )
  end
  local base_repo = type(base.repo) == 'table' and base.repo.full_name
  local head_repo = type(head.repo) == 'table' and head.repo.full_name
  local read_only
  if raw.state ~= nil and raw.state ~= 'open' then
    read_only = raw.merged and 'The pull request is merged'
      or 'The pull request is closed'
  end
  return {
    id = tostring(n),
    title = text(raw.title, ''),
    author = type(raw.user) == 'table' and text(raw.user.login, 'ghost')
      or 'ghost',
    body = text(raw.body, ''),
    url = text(raw.html_url, ''),
    base_ref = base.ref,
    head_ref = text(head.ref, ''),
    base_sha = base.sha,
    head_sha = head.sha,
    fetch = fetch,
    -- A deleted fork leaves no repository behind
    fork = not head_repo or head_repo ~= base_repo,
    read_only = read_only,
  }
end

--- Every row at `path`, a page at a time
---
--- A page that fails fails the whole listing; one that is full at
--- `M.MAX_PAGES` stops it, with `capped`.
---@param remote DyForgeRemote
---@param path string Already holding a query, `per_page` among it
---@param on_done fun(rows?: table[], err?: string, capped?: boolean)
local function pages(remote, path, on_done)
  local rows = {}
  local function page(index)
    forge.api(remote, ('%s&page=%d'):format(path, index), function(data, err)
      if data == nil then return on_done(nil, err) end
      if type(data) ~= 'table' or not vim.islist(data) then
        return on_done(nil, 'GitHub answered with something not a list')
      end
      vim.list_extend(rows, data)
      if #data < M.PER_PAGE then return on_done(rows, nil, false) end
      if index >= M.MAX_PAGES then return on_done(rows, nil, true) end
      page(index + 1)
    end)
  end
  page(1)
end

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
          'GitHub: '
            .. (
              type(first) == 'table' and text(first.message) or 'GraphQL error'
            )
        )
      end
      if type(answer) ~= 'table' or type(answer.data) ~= 'table' then
        return on_done(nil, 'GitHub answered with no data')
      end
      on_done(answer.data)
    end
  )
end

--- Hand `on_done` the login `gh` is signed in with on `remote`'s host
---@param remote DyForgeRemote
---@param on_done fun(login?: string, err?: string)
local function login(remote, on_done)
  local known = logins[remote.host]
  if known then return on_done(known) end
  forge.api(remote, 'user', function(data, err)
    local name = type(data) == 'table' and text(data.login)
    if not name then
      return on_done(nil, err or 'GitHub did not say who is signed in')
    end
    -- Logins match whatever their case
    logins[remote.host] = name:lower()
    on_done(logins[remote.host])
  end)
end

--- Open pull requests, and whether my review is asked on each
---@param remote DyForgeRemote
---@param cb fun(pulls?: DyReviewPull[], err?: string, capped?: boolean)
function M.list(remote, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  login(remote, function(me, err)
    if not me then return cb(nil, err) end
    local path = ('%s/pulls?state=open&per_page=%d'):format(
      repo_path(remote),
      M.PER_PAGE
    )
    pages(remote, path, function(rows, list_err, capped)
      if not rows then return cb(nil, list_err) end
      local pulls = {}
      for _, raw in ipairs(rows) do
        local pull = to_pull(raw)
        if not pull then
          return cb(nil, 'GitHub answered with a malformed pull request')
        end
        pull.requested = false
        for _, user in ipairs(raw.requested_reviewers or {}) do
          if type(user) == 'table' and text(user.login, ''):lower() == me then
            pull.requested = true
          end
        end
        pulls[#pulls + 1] = pull
      end
      cb(pulls, nil, capped)
    end)
  end)
end

--- The open pull request of `branch`, nil without an error when it has none
---@param remote DyForgeRemote
---@param branch string
---@param cb fun(pull?: DyReviewPull, err?: string)
function M.for_branch(remote, branch, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  local owner = repo(remote)
  local path = ('%s/pulls?state=open&head=%s&per_page=1'):format(
    repo_path(remote),
    forge.encode(owner .. ':' .. branch)
  )
  forge.api(remote, path, function(data, err)
    if data == nil then return cb(nil, err) end
    if type(data) ~= 'table' or not vim.islist(data) then
      return cb(nil, 'GitHub answered with something not a list')
    end
    if data[1] == nil then return cb(nil) end
    local pull = to_pull(data[1])
    if not pull then
      return cb(nil, 'GitHub answered with a malformed pull request')
    end
    cb(pull)
  end)
end

--- Pull request `id`
---@param remote DyForgeRemote
---@param id string
---@param cb fun(pull?: DyReviewPull, err?: string)
function M.get(remote, id, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if type(id) ~= 'string' or not id:match('^%d+$') then
    return cb(nil, 'Not a pull request number: ' .. tostring(id))
  end
  forge.api(
    remote,
    ('%s/pulls/%s'):format(repo_path(remote), id),
    function(data, err)
      if data == nil then return cb(nil, err) end
      local pull = to_pull(data)
      if not pull then
        return cb(nil, 'GitHub answered with a malformed pull request')
      end
      cb(pull)
    end
  )
end

local THREADS_QUERY = [[
query DyReviewThreads($owner: String!, $name: String!, $number: Int!, $cursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $cursor) {
        pageInfo { hasNextPage endCursor }
        nodes {
          id path line startLine originalLine originalStartLine diffSide
          isResolved subjectType
          comments(first: 100) {
            pageInfo { hasNextPage }
            nodes { author { login } body createdAt }
          }
        }
      }
    }
  }
}]]

--- A review thread of GraphQL as `:DyReview` keeps it
---@param node table
---@return DyReviewThread
local function to_thread(node)
  local thread = {
    id = text(node.id, ''),
    path = text(node.path),
    side = node.diffSide == 'LEFT' and 'old' or 'new',
    resolved = node.isResolved == true,
    comments = {},
  }
  -- An outdated thread keeps only the line it was written on
  if node.subjectType ~= 'FILE' then
    thread.line = int(node.line) or int(node.originalLine)
    thread.start_line = int(node.startLine) or int(node.originalStartLine)
  end
  local comments = type(node.comments) == 'table' and node.comments.nodes
  for _, comment in ipairs(type(comments) == 'table' and comments or {}) do
    local author = type(comment.author) == 'table' and comment.author
    table.insert(thread.comments, {
      -- A deleted account has no author
      author = author and text(author.login, 'ghost') or 'ghost',
      body = text(comment.body, ''),
      time = text(comment.createdAt, ''),
    })
  end
  return thread
end

--- The number of `pull`, as GraphQL takes it
---@param pull DyReviewPull
---@return integer?
local function number(pull)
  return type(pull.id) == 'string'
      and pull.id:match('^%d+$')
      and tonumber(pull.id)
    or nil
end

--- Every review thread of `pull`, with its comments
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param cb fun(threads?: DyReviewThread[], err?: string, capped?: boolean)
function M.threads(remote, pull, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  local n = number(pull)
  if not n then return cb(nil, 'Not a pull request number') end
  local owner, name = repo(remote)
  local threads, capped = {}, false
  local function page(index, cursor)
    graphql(
      remote,
      THREADS_QUERY,
      { owner = owner, name = name, number = n, cursor = cursor },
      function(data, err)
        if not data then return cb(nil, err) end
        local pr = type(data.repository) == 'table'
          and data.repository.pullRequest
        local list = type(pr) == 'table' and pr.reviewThreads
        if type(list) ~= 'table' or type(list.nodes) ~= 'table' then
          return cb(nil, 'GitHub answered with no review threads')
        end
        for _, node in ipairs(list.nodes) do
          if type(node) == 'table' then
            local more = type(node.comments) == 'table'
              and type(node.comments.pageInfo) == 'table'
              and node.comments.pageInfo.hasNextPage
            -- A thread's later comments are past what one page holds
            if more then capped = true end
            table.insert(threads, to_thread(node))
          end
        end
        local info = type(list.pageInfo) == 'table' and list.pageInfo or {}
        if not info.hasNextPage then return cb(threads, nil, capped) end
        if index >= M.MAX_PAGES or not text(info.endCursor) then
          return cb(threads, nil, true)
        end
        page(index + 1, info.endCursor)
      end
    )
  end
  page(1, nil)
end

--- The id a draft imported from forge comment `id` goes by, the same on
--- every import
---@param id any
---@return string
local function forge_draft_id(id)
  return vim.fn.sha256('github:' .. tostring(id)):sub(1, 12)
end

--- My pending review of `pull`, nil without an error when there is none,
--- every review of `pull` GitHub listed, and my login
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(review?: table, err?: string, reviews?: table[], me?: string)
local function pending_review(remote, pull, on_done)
  login(remote, function(me, err)
    if not me then return on_done(nil, err) end
    local path = ('%s/pulls/%s/reviews?per_page=%d'):format(
      repo_path(remote),
      pull.id,
      M.PER_PAGE
    )
    pages(remote, path, function(rows, list_err, capped)
      if not rows then return on_done(nil, list_err) end
      -- The pending review may be on a page never read
      if capped then
        return on_done(nil, 'More reviews than can be read on GitHub')
      end
      for _, review in ipairs(rows) do
        if
          type(review) == 'table'
          and review.state == 'PENDING'
          and type(review.user) == 'table'
          and text(review.user.login, ''):lower() == me
        then
          if not (int(review.id) and text(review.node_id)) then
            return on_done(nil, 'GitHub answered with a malformed review')
          end
          return on_done(review, nil, rows, me)
        end
      end
      on_done(nil, nil, rows, me)
    end)
  end)
end

--- A comment of a pending review as a draft
---@param comment table
---@return DyReviewDraft
local function to_draft(comment)
  local draft = {
    id = forge_draft_id(comment.id),
    origin = 'forge',
    state = 'ready',
    path = text(comment.path, ''),
    side = comment.side == 'LEFT' and 'old' or 'new',
    body = text(comment.body, ''),
  }
  local line = int(comment.line) or int(comment.original_line)
  if comment.subject_type == 'file' or not line then
    -- The line a file-level comment names is the one its text starts with
    draft.file_level = true
    draft.line = tonumber(draft.body:match('^L(%d+): ')) or 1
    return draft
  end
  draft.line = line
  local start = int(comment.start_line) or int(comment.original_start_line)
  if start and start < line then draft.start_line = start end
  return draft
end

--- Every comment of pending review `review` of `pull`
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param review table
---@param on_done fun(comments?: table[], err?: string)
local function review_comments(remote, pull, review, on_done)
  local path = ('%s/pulls/%s/reviews/%d/comments?per_page=%d'):format(
    repo_path(remote),
    pull.id,
    review.id,
    M.PER_PAGE
  )
  pages(remote, path, function(rows, err, capped)
    if not rows then return on_done(nil, err) end
    -- Half the review would hide what it holds
    if capped then
      return on_done(nil, 'More pending comments than can be read on GitHub')
    end
    for _, comment in ipairs(rows) do
      if type(comment) ~= 'table' or not int(comment.id) then
        return on_done(nil, 'GitHub answered with a malformed comment')
      end
    end
    on_done(rows)
  end)
end

--- The comments of my pending review of `pull`, as drafts from the forge
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param cb fun(drafts?: DyReviewDraft[], err?: string)
function M.pending(remote, pull, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if not number(pull) then return cb(nil, 'Not a pull request number') end
  pending_review(remote, pull, function(review, err)
    if err then return cb(nil, err) end
    if not review then return cb({}) end
    review_comments(remote, pull, review, function(comments, list_err)
      if not comments then return cb(nil, list_err) end
      cb(vim.tbl_map(to_draft, comments))
    end)
  end)
end

--- The text a draft sends: its body, then its suggestion, and for a
--- file-level comment the line it is about first
---@param draft DyReviewDraft
---@return string
local function body_of(draft)
  local body = draft.body or ''
  if draft.suggestion then
    local fenced = M.suggestion(draft.suggestion)
    body = body ~= '' and (body .. '\n\n' .. fenced) or fenced
  end
  if draft.file_level then body = ('L%d: %s'):format(draft.line, body) end
  return body
end

--- The start of a draft's range, nil for a single line
---@param draft DyReviewDraft
---@return integer?
local function range_start(draft)
  if draft.start_line and draft.start_line < draft.line then
    return draft.start_line
  end
end

--- A draft as the input of `addPullRequestReviewThread`
---@param review_id string
---@param draft DyReviewDraft
---@return table
local function thread_input(review_id, draft)
  local input = {
    pullRequestReviewId = review_id,
    path = draft.path,
    body = body_of(draft),
  }
  if draft.file_level then
    input.subjectType = 'FILE'
    return input
  end
  input.subjectType = 'LINE'
  input.line, input.side = draft.line, SIDES[draft.side]
  local start = range_start(draft)
  if start then
    input.startLine, input.startSide = start, input.side
  end
  return input
end

local PULL_ID = [[
query DyReviewPullId($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) { pullRequest(number: $number) { id } }
}]]

local CREATE_REVIEW = [[
mutation DyReviewCreate($input: AddPullRequestReviewInput!) {
  addPullRequestReview(input: $input) { pullRequestReview { id databaseId } }
}]]

local RESOLVE = [[
mutation DyReviewResolve($input: ResolveReviewThreadInput!) {
  resolveReviewThread(input: $input) { thread { id isResolved } }
}]]

local ADD_THREAD = [[
mutation DyReviewAddThread($input: AddPullRequestReviewThreadInput!) {
  addPullRequestReviewThread(input: $input) {
    thread { id comments(first: 1) { nodes { databaseId } } }
  }
}]]

local ADD_REPLY = [[
mutation DyReviewReply($input: AddPullRequestReviewThreadReplyInput!) {
  addPullRequestReviewThreadReply(input: $input) { comment { id databaseId } }
}]]

local SUBMIT_REVIEW = [[
mutation DyReviewSubmit($input: SubmitPullRequestReviewInput!) {
  submitPullRequestReview(input: $input) { pullRequestReview { id } }
}]]

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

--- The forge id of comment `comment` of pending review `review`: the review
--- is in it, so a later submit tells what that review should hold
---@param review integer
---@param comment integer
---@return string
local function posted_id(review, comment)
  return ('%d/%d'):format(review, comment)
end

--- The review and comment of a forge id `posted_id` made, nil for another
---@param posted any
---@return integer? review
---@return integer? comment
local function parse_posted(posted)
  if type(posted) ~= 'string' then return nil end
  local review, comment = posted:match('^(%d+)/(%d+)$')
  return tonumber(review), tonumber(comment)
end

--- The id `pending` gives the comment a forge id `posted` names, nil for a
--- forge id naming none
---@param posted string
---@return string?
function M.import_id(posted)
  local _, comment = parse_posted(posted)
  return comment and forge_draft_id(comment) or nil
end

--- Why a pending review cannot be submitted as it is
local CHANGED = 'the pending review on GitHub no longer matches the drafts '
  .. 'here; open the pull request again'

--- Why pending review `review` is not what the drafts say it holds, nil when
--- it is
---
--- It holds the imported drafts not yet sent and every draft sent into it
--- before; a comment more or one less means the review or the drafts here
--- changed since, and submitting would publish what no one confirmed.
---@param review table
---@param comments table[]
---@param drafts DyReviewDraft[]
---@return string? err
---@return table<string, integer> comment_of Comment id by imported draft id
local function changed(review, comments, drafts)
  local imported, sent, comment_of = {}, {}, {}
  for _, draft in ipairs(drafts) do
    local in_review, comment = parse_posted(draft.posted)
    if comment and in_review == review.id then
      sent[comment] = true
    elseif not draft.posted and draft.origin == 'forge' then
      imported[draft.id] = true
    end
  end
  local held = 0
  for _, comment in ipairs(comments) do
    local id = forge_draft_id(comment.id)
    if imported[id] then
      comment_of[id] = comment.id
    elseif not sent[comment.id] then
      return CHANGED, comment_of
    end
    held = held + 1
  end
  local expected = vim.tbl_count(imported) + vim.tbl_count(sent)
  if held ~= expected then return CHANGED, comment_of end
  return nil, comment_of
end

--- Hand `on_done` a new pending review of `pull`, on the head GitHub knows
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(review?: { id: integer, node_id: string }, err?: string)
local function create_review(remote, pull, on_done)
  local owner, name = repo(remote)
  graphql(
    remote,
    PULL_ID,
    { owner = owner, name = name, number = number(pull) },
    function(data, err)
      if not data then return on_done(nil, err) end
      local pr = type(data.repository) == 'table'
        and data.repository.pullRequest
      local pull_id = type(pr) == 'table' and text(pr.id)
      if not pull_id then
        return on_done(nil, 'GitHub answered with no pull request')
      end
      graphql(
        remote,
        CREATE_REVIEW,
        { input = { pullRequestId = pull_id, commitOID = pull.head_sha } },
        function(created, create_err)
          if not created then return on_done(nil, create_err) end
          local review = type(created.addPullRequestReview) == 'table'
            and created.addPullRequestReview.pullRequestReview
          if
            type(review) ~= 'table'
            or not text(review.id)
            or not int(review.databaseId)
          then
            return on_done(nil, 'GitHub started no review')
          end
          on_done({ id = review.databaseId, node_id = review.id })
        end
      )
    end
  )
end

--- Resolve the thread of each of `drafts`, reporting a draft with nothing
--- more to send
---
--- A thread is resolved before its reply goes in: resolving again does
--- nothing, while a reply sent twice shows twice.
---@param remote DyForgeRemote
---@param drafts DyReviewDraft[]
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param on_done fun(err?: string)
local function resolve_all(remote, drafts, progress, on_done)
  in_turn(drafts, function(draft, next)
    graphql(
      remote,
      RESOLVE,
      { input = { threadId = draft.reply_to } },
      function(data, err)
        if not data then return next(err) end
        if body_of(draft) == '' then progress(draft, draft.reply_to) end
        next()
      end
    )
  end, on_done)
end

--- Fill pending review `review` and submit it: resolutions, then new
--- threads, then replies, each draft reported once it is in the review, and
--- the verdict last
---@param remote DyForgeRemote
---@param review { id: integer, node_id: string }
---@param groups { resolves: DyReviewDraft[], new: DyReviewDraft[], replies: DyReviewDraft[], imported: DyReviewDraft[] }
---@param comment_of table<string, integer>
---@param verdict { event: string, body?: string }
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param on_done fun(err?: string)
local function fill_and_submit(
  remote,
  review,
  groups,
  comment_of,
  verdict,
  progress,
  on_done
)
  local function add_thread(draft, next)
    graphql(
      remote,
      ADD_THREAD,
      { input = thread_input(review.node_id, draft) },
      function(data, err)
        if not data then return next(err) end
        local added = type(data.addPullRequestReviewThread) == 'table'
          and data.addPullRequestReviewThread.thread
        local comments = type(added) == 'table'
          and type(added.comments) == 'table'
          and added.comments.nodes
        local first = type(comments) == 'table' and comments[1]
        local id = type(first) == 'table' and int(first.databaseId)
        if not id then return next('GitHub added no review thread') end
        progress(draft, posted_id(review.id, id))
        next()
      end
    )
  end
  local function add_reply(draft, next)
    local input = {
      pullRequestReviewId = review.node_id,
      pullRequestReviewThreadId = draft.reply_to,
      body = body_of(draft),
    }
    graphql(remote, ADD_REPLY, { input = input }, function(data, err)
      if not data then return next(err) end
      local reply = type(data.addPullRequestReviewThreadReply) == 'table'
        and data.addPullRequestReviewThreadReply.comment
      local id = type(reply) == 'table' and int(reply.databaseId)
      if not id then return next('GitHub added no reply') end
      progress(draft, posted_id(review.id, id))
      next()
    end)
  end
  local function submit()
    local input = {
      pullRequestReviewId = review.node_id,
      event = verdict.event,
      body = verdict.body,
    }
    graphql(remote, SUBMIT_REVIEW, { input = input }, function(data, err)
      if not data then return on_done(err) end
      for _, draft in ipairs(groups.imported) do
        progress(draft, posted_id(review.id, comment_of[draft.id]))
      end
      on_done(nil)
    end)
  end
  resolve_all(remote, groups.resolves, progress, function(resolve_err)
    if resolve_err then return on_done(resolve_err) end
    in_turn(groups.new, add_thread, function(thread_err)
      if thread_err then return on_done(thread_err) end
      in_turn(groups.replies, add_reply, function(reply_err)
        if reply_err then return on_done(reply_err) end
        submit()
      end)
    end)
  end)
end

--- The state a review is left in by each event
local SUBMITTED_AS = {
  APPROVE = 'APPROVED',
  REQUEST_CHANGES = 'CHANGES_REQUESTED',
  COMMENT = 'COMMENTED',
}

--- The drafts sent into a review GitHub no longer lists, and the review
--- the most recently sent draft went into
---@param drafts DyReviewDraft[]
---@param pending? table The pending review, whose drafts are checked apart
---@param reviews table[] Every review of the pull request
---@return string[] lost Their local ids
---@return integer? last
local function sent_before(drafts, pending, reviews)
  local listed = {}
  for _, row in ipairs(reviews) do
    if type(row) == 'table' and int(row.id) then listed[row.id] = true end
  end
  local lost, last, newest = {}, nil, -1
  for _, draft in ipairs(drafts) do
    local review, comment = parse_posted(draft.posted)
    if comment then
      if comment > newest then
        last, newest = review, comment
      end
      if not (pending and review == pending.id) and not listed[review] then
        table.insert(lost, draft.id)
      end
    end
  end
  return lost, last
end

--- Whether review `last` is the one asked for again: my newest review out
--- on GitHub, left with `event` and `body`. A submit that timed out after it
--- reached GitHub reads that way; any other verdict or text is a new one.
---@param reviews table[]
---@param me string
---@param last? integer
---@param event string
---@param body? string
---@return boolean
local function already_out(reviews, me, last, event, body)
  if not last then return false end
  local newest
  for _, row in ipairs(reviews) do
    if
      type(row) == 'table'
      and int(row.id)
      and row.state ~= 'PENDING'
      and type(row.user) == 'table'
      and text(row.user.login, ''):lower() == me
      and (not newest or row.id > newest.id)
    then
      newest = row
    end
  end
  return newest ~= nil
    and newest.id == last
    and newest.state == SUBMITTED_AS[event]
    and text(newest.body, '') == (body or '')
end

--- Send `drafts` with `review`'s verdict and text
---
--- Everything goes through one pending review: mine on GitHub when there is
--- one, a new one otherwise. Threads are resolved, new threads and replies
--- added to it, and it is submitted with the verdict last. Each draft is
--- reported through `progress` as soon as it is in the review, so a submit
--- cut short and run again never adds it twice; a draft already `posted` is
--- never sent. A failed call stops the submit there and is never tried
--- again here: one that timed out may still have reached GitHub.
---
--- Refused before any write: a pending review holding more or less than the
--- drafts say, since submitting it publishes all it holds; and drafts sent
--- into a pending review since deleted, named in `info.lost`, which only
--- the caller may send again. With nothing new, the threads are only
--- resolved when the review asked for is already out (`info.already`, its
--- id) or would be an empty comment GitHub refuses (`info.skipped`); any
--- other verdict goes out on its own.
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param drafts DyReviewDraft[]
---@param review { verdict: string, body?: string }
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param cb fun(err?: string, info?: { lost?: string[], already?: integer, skipped?: string })
function M.submit(remote, pull, drafts, review, progress, cb)
  local verdict = type(review) == 'table' and review.verdict
  local event = EVENTS[verdict]
  if not event then return cb('GitHub has no verdict ' .. tostring(verdict)) end
  local bad = bad_remote(remote)
  if bad then return cb(bad) end
  if not number(pull) then return cb('Not a pull request number') end
  local groups = { resolves = {}, new = {}, replies = {}, imported = {} }
  for _, draft in ipairs(drafts) do
    if not draft.posted then
      if draft.origin == 'forge' then
        table.insert(groups.imported, draft)
      elseif draft.reply_to then
        if draft.resolve then table.insert(groups.resolves, draft) end
        if body_of(draft) ~= '' then table.insert(groups.replies, draft) end
      else
        table.insert(groups.new, draft)
      end
    end
  end
  local nothing_new = #groups.new == 0
    and #groups.replies == 0
    and #groups.imported == 0
  local empty_comment = event == 'COMMENT'
    and (review.body == nil or review.body == '')
  local verdict_input = { event = event, body = review.body }
  local function fill(pending, comment_of)
    fill_and_submit(
      remote,
      pending,
      groups,
      comment_of,
      verdict_input,
      progress,
      cb
    )
  end
  ---@param info table
  local function resolve_only(info)
    resolve_all(remote, groups.resolves, progress, function(err)
      if err then return cb(err) end
      cb(nil, info)
    end)
  end
  local SKIPPED = { skipped = 'empty comment review' }
  pending_review(remote, pull, function(pending, err, reviews, me)
    if err then return cb(err) end
    reviews = reviews or {}
    local lost, last = sent_before(drafts, pending, reviews)
    if #lost > 0 then
      return cb(
        ('%d drafts went into a pending review that was deleted on GitHub'):format(
          #lost
        ),
        { lost = lost }
      )
    end
    if not pending then
      -- Submitted or deleted on GitHub since they were imported: sending
      -- them again could show them twice
      if #groups.imported > 0 then
        return cb(
          'The pending review on GitHub these drafts came from is gone; '
            .. 'open the pull request again'
        )
      end
      if
        nothing_new
        and me
        and already_out(reviews, me, last, event, review.body)
      then
        return resolve_only({ already = last })
      end
      if nothing_new and empty_comment then return resolve_only(SKIPPED) end
      return create_review(remote, pull, function(created, create_err)
        if not created then return cb(create_err) end
        fill(created, {})
      end)
    end
    review_comments(remote, pull, pending, function(comments, list_err)
      if not comments then return cb(list_err) end
      local why, comment_of = changed(pending, comments, drafts)
      if why then return cb(why) end
      if nothing_new and #comments == 0 and empty_comment then
        return resolve_only(SKIPPED)
      end
      fill({ id = pending.id, node_id = pending.node_id }, comment_of)
    end)
  end)
end

--- GitHub's suggested change of the lines commented on
---@param lines string[]
---@return string
function M.suggestion(lines)
  return '```suggestion\n' .. table.concat(lines, '\n') .. '\n```'
end

return M
