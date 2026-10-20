--- Azure DevOps pull requests for `:DyReview`, through `az devops invoke`
---
--- Every call is a `DyForgeAzureCall` of the Git REST API (area `git`) and
--- goes through `util.forge`, so `az` holds the token and has a deadline.
--- Listings are read a page at a time to the end or to `M.MAX_PAGES`.
---
--- Azure DevOps has no draft comments: each thread or reply is published
--- the moment it is posted, and `pending` has nothing to import. A comment
--- is placed by path and line on either side, against the pull request's
--- last iteration, with the change tracking id that iteration gives its
--- file. The verdict is my vote, set through my reviewer entry, whose id
--- is the signed-in user's (`connectionData`).
---
--- A draft sent goes by `<thread id>`, or `<thread id>/<comment id>` for a
--- reply; a later submit checks every one of them is still on Azure DevOps
--- before it writes anything.
---@class DyReviewAzure: DyReviewForge
local M = {}

local forge = require('util.forge')

--- Pages read before a listing stops and says it was capped
M.MAX_PAGES = 20

--- Pull requests asked for per page
M.PER_PAGE = 100

--- Changed files asked for per page, the most Azure DevOps hands over
M.CHANGES_PER_PAGE = 2000

--- Pull requests a branch is looked up among: forks may share its name
M.BRANCH_ROWS = 20

M.verdicts = {
  { id = 'approve', label = 'Approve' },
  { id = 'approve_with_suggestions', label = 'Approve with suggestions' },
  { id = 'wait_for_author', label = 'Wait for author' },
  { id = 'reject', label = 'Reject' },
  { id = 'no_vote', label = 'No vote' },
}

--- The vote of each verdict
M.VOTES = {
  approve = 10,
  approve_with_suggestions = 5,
  no_vote = 0,
  wait_for_author = -5,
  reject = -10,
}

--- Why a pull request whose source cannot be fetched opens read-only
M.FORK = 'the source branch lives in a fork that cannot be fetched'

--- The thread statuses that read as resolved
local RESOLVED =
  { fixed = true, wontFix = true, closed = true, byDesign = true }

--- Merge statuses that leave no merge ref behind
local NO_MERGE = { conflicts = true, failure = true, rejectedByPolicy = true }

--- `active`, as a new thread's status is written
local ACTIVE = 1

--- A plain text comment, as a new comment's type is written
local TEXT = 1

--- My identity id, lower case, by organization, asked once a session
---@type table<string, string>
local ids = {}

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
  local org, project, repo = remote.org, remote.project, remote.repo
  if
    type(org) ~= 'string'
    or not org:match('^%w[%w-]*$')
    or type(project) ~= 'string'
    or project == ''
    or type(repo) ~= 'string'
    or repo == ''
  then
    return 'Not an Azure DevOps repository: ' .. tostring(remote.slug)
  end
end

--- The number of `pull`, nil when it is not one
---@param pull DyReviewPull
---@return integer?
local function number(pull)
  return type(pull.id) == 'string' and tonumber(pull.id:match('^%d+$')) or nil
end

--- A call of the Git API on `remote`'s repository, `route` added to it
---@param remote DyForgeRemote
---@param resource string
---@param route? table<string, string|integer>
---@param query? table<string, string|integer>
---@return DyForgeAzureCall
local function call(remote, resource, route, query)
  return {
    area = 'git',
    resource = resource,
    route = vim.tbl_extend(
      'force',
      { project = remote.project, repositoryId = remote.repo },
      route or {}
    ),
    query = query,
  }
end

--- A call on pull request `pull`, `route` added to it
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param resource string
---@param route? table<string, string|integer>
---@param query? table<string, string|integer>
---@return DyForgeAzureCall
local function on_pull(remote, pull, resource, route, query)
  return call(
    remote,
    resource,
    vim.tbl_extend('force', { pullRequestId = number(pull) }, route or {}),
    query
  )
end

--- The rows of a `{ count, value }` answer, nil when it is not one or holds
--- fewer rows than it counts
---@param data any
---@return table[]? rows
---@return string? err
local function rows_of(data)
  local rows = tbl(data) and tbl(data.value)
  if not rows or not vim.islist(rows) then
    return nil, 'Azure DevOps answered with something not a list'
  end
  local count = int(data.count)
  if count and count > #rows then
    return nil, ('Azure DevOps handed over %d of %d rows'):format(#rows, count)
  end
  return rows
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

--- The commit id of a commit ref, nil for none
---@param commit any
---@return string?
local function commit_id(commit)
  return tbl(commit) and text(commit.commitId) or nil
end

--- A pull request of the API as `:DyReview` keeps it, nil when it lacks what
--- a review needs: its last merge is worked out a moment after it is opened
---
--- The merge ref holds the head as its second parent and the base as its
--- first, so it alone brings both, from a fork too. Without one (a merge
--- with conflicts) the head comes from the source branch, which a fork's
--- is not in this repository.
---@param remote DyForgeRemote
---@param raw any
---@return DyReviewPull?
local function to_pull(remote, raw)
  if type(raw) ~= 'table' or not int(raw.pullRequestId) then return nil end
  local head_sha = commit_id(raw.lastMergeSourceCommit)
  local base_sha = commit_id(raw.lastMergeTargetCommit)
  local base_ref = (text(raw.targetRefName, '') --[[@as string]]):gsub(
    '^refs/heads/',
    ''
  )
  if not (head_sha and base_sha) or base_ref == '' then return nil end
  local head_ref = (text(raw.sourceRefName, '') --[[@as string]]):gsub(
    '^refs/heads/',
    ''
  )
  local n = raw.pullRequestId
  local refs = ('refs/dyneo/review/azure-%d/'):format(n)
  local fork = tbl(raw.forkSource) ~= nil
  local fetch, read_only = {}, nil
  if commit_id(raw.lastMergeCommit) and not NO_MERGE[raw.mergeStatus] then
    fetch[1] = ('+refs/pull/%d/merge:%smerge'):format(n, refs)
  else
    if fork then
      read_only = M.FORK
    elseif plain_ref(head_ref) then
      fetch[#fetch + 1] = ('+refs/heads/%s:%shead'):format(head_ref, refs)
    else
      read_only = 'the source branch has a name that cannot be fetched'
    end
    if plain_ref(base_ref) then
      fetch[#fetch + 1] = ('+refs/heads/%s:%sbase'):format(base_ref, refs)
    end
  end
  if raw.status ~= nil and raw.status ~= 'active' then
    read_only = raw.status == 'completed' and 'The pull request is merged'
      or raw.status == 'abandoned' and 'The pull request is abandoned'
      or 'The pull request is closed'
  end
  local author = tbl(raw.createdBy)
  return {
    id = tostring(n),
    title = text(raw.title, ''),
    -- A deleted account has no author
    author = author and text(author.displayName, 'ghost') or 'ghost',
    body = text(raw.description, ''),
    url = ('https://dev.azure.com/%s/%s/_git/%s/pullrequest/%d'):format(
      remote.org,
      forge.encode(remote.project),
      forge.encode(remote.repo),
      n
    ),
    base_ref = base_ref,
    head_ref = head_ref,
    base_sha = base_sha,
    head_sha = head_sha,
    fetch = fetch,
    fork = fork,
    read_only = read_only,
  }
end

--- Hand `on_done` the id of the user `az` is signed in as, lower case
---@param remote DyForgeRemote
---@param on_done fun(id?: string, err?: string)
local function whoami(remote, on_done)
  local known = ids[remote.org]
  if known then return on_done(known) end
  forge.api(
    remote,
    { area = 'Location', resource = 'connectionData', route = {} },
    function(data, err)
      local user = tbl(data) and tbl(data.authenticatedUser)
      local id = user and text(user.id)
      if not id then
        return on_done(nil, err or 'Azure DevOps did not say who is signed in')
      end
      -- Ids are GUIDs, written in either case
      ids[remote.org] = id:lower()
      on_done(ids[remote.org])
    end
  )
end

--- Whether `identity` is the user `me`
---@param identity any
---@param me string
---@return boolean
local function is_me(identity, me)
  local id = tbl(identity) and text(identity.id)
  return id ~= nil and id:lower() == me
end

--- Active pull requests, and whether my review is asked on each
---
--- One whose merge Azure DevOps has not worked out yet is left out: it
--- cannot be reviewed until it has.
---@param remote DyForgeRemote
---@param cb fun(pulls?: DyReviewPull[], err?: string, capped?: boolean)
function M.list(remote, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  whoami(remote, function(me, err)
    if not me then return cb(nil, err) end
    local pulls = {}
    local function page(index)
      local query = {
        ['searchCriteria.status'] = 'active',
        ['$top'] = M.PER_PAGE,
        ['$skip'] = (index - 1) * M.PER_PAGE,
      }
      forge.api(
        remote,
        call(remote, 'pullRequests', nil, query),
        function(data, list_err)
          if data == nil then return cb(nil, list_err) end
          local rows, rows_err = rows_of(data)
          if not rows then return cb(nil, rows_err) end
          for _, raw in ipairs(rows) do
            if type(raw) ~= 'table' or not int(raw.pullRequestId) then
              return cb(
                nil,
                'Azure DevOps answered with a malformed pull request'
              )
            end
            local pull = to_pull(remote, raw)
            if pull then
              pull.requested = false
              for _, reviewer in ipairs(tbl(raw.reviewers) or {}) do
                if is_me(reviewer, me) then pull.requested = true end
              end
              pulls[#pulls + 1] = pull
            end
          end
          if #rows < M.PER_PAGE then return cb(pulls, nil, false) end
          if index >= M.MAX_PAGES then return cb(pulls, nil, true) end
          page(index + 1)
        end
      )
    end
    page(1)
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
    call(remote, 'pullRequests', { pullRequestId = id }),
    function(data, err)
      if data == nil then return cb(nil, err) end
      local pull = to_pull(remote, data)
      if not pull then
        return cb(
          nil,
          'Azure DevOps answered with a pull request whose merge is not ready'
        )
      end
      cb(pull)
    end
  )
end

--- The active pull request of `branch` within the repository, nil without
--- an error when it has none. One from a fork's branch of the same name is
--- someone else's.
---@param remote DyForgeRemote
---@param branch string
---@param cb fun(pull?: DyReviewPull, err?: string)
function M.for_branch(remote, branch, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  local query = {
    ['searchCriteria.status'] = 'active',
    ['searchCriteria.sourceRefName'] = 'refs/heads/' .. branch,
    ['$top'] = M.BRANCH_ROWS,
  }
  forge.api(
    remote,
    call(remote, 'pullRequests', nil, query),
    function(data, err)
      if data == nil then return cb(nil, err) end
      local rows, rows_err = rows_of(data)
      if not rows then return cb(nil, rows_err) end
      for _, raw in ipairs(rows) do
        if
          type(raw) == 'table'
          and int(raw.pullRequestId)
          and not tbl(raw.forkSource)
        then
          -- The listing cuts the description short
          return M.get(remote, tostring(raw.pullRequestId), cb)
        end
      end
      cb(nil)
    end
  )
end

--- Every thread of `pull`, failing rather than handing over part of them
---
--- The API answers them all at once, with their count.
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(rows?: table[], err?: string)
local function all_threads(remote, pull, on_done)
  forge.api(
    remote,
    on_pull(remote, pull, 'pullRequestThreads'),
    function(data, err)
      if data == nil then return on_done(nil, err) end
      local rows, rows_err = rows_of(data)
      if not rows then return on_done(nil, rows_err) end
      for _, row in ipairs(rows) do
        if type(row) ~= 'table' or not int(row.id) then
          return on_done(nil, 'Azure DevOps answered with a malformed thread')
        end
      end
      on_done(rows)
    end
  )
end

--- The comments of a thread that are still there and written by someone
---@param row table
---@return table[]
local function live_comments(row)
  local live = {}
  for _, comment in ipairs(tbl(row.comments) or {}) do
    if
      type(comment) == 'table'
      and comment.isDeleted ~= true
      and comment.commentType ~= 'system'
    then
      live[#live + 1] = comment
    end
  end
  return live
end

--- The line of a comment position, nil for none
---@param position any
---@return integer?
local function line_of(position)
  return tbl(position) and int(position.line) or nil
end

--- A thread on a file as `:DyReview` keeps it, nil for a deleted one, one
--- on the pull request itself or one Azure DevOps wrote
---@param row table
---@return DyReviewThread?
local function to_thread(row)
  local context = tbl(row.threadContext)
  local file = context and text(context.filePath)
  if row.isDeleted == true or not file then return nil end
  ---@cast context table
  local comments = live_comments(row)
  if #comments == 0 then return nil end
  local thread = {
    id = tostring(row.id),
    path = (file:gsub('^/', '')),
    side = 'new',
    resolved = RESOLVED[row.status] == true,
    comments = {},
  }
  local first = line_of(context.rightFileStart)
  local last = line_of(context.rightFileEnd)
  if not (first or last) then
    first, last = line_of(context.leftFileStart), line_of(context.leftFileEnd)
    if first or last then thread.side = 'old' end
  end
  thread.line = last or first
  if first and thread.line and first < thread.line then
    thread.start_line = first
  end
  for _, comment in ipairs(comments) do
    local author = tbl(comment.author)
    table.insert(thread.comments, {
      -- A deleted account has no author
      author = author and text(author.displayName, 'ghost') or 'ghost',
      body = text(comment.content, ''),
      time = text(comment.publishedDate, ''),
    })
  end
  return thread
end

--- Every thread on a file of `pull`, with its comments
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param cb fun(threads?: DyReviewThread[], err?: string, capped?: boolean)
function M.threads(remote, pull, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if not number(pull) then return cb(nil, 'Not a pull request number') end
  all_threads(remote, pull, function(rows, err)
    if not rows then return cb(nil, err) end
    local threads = {}
    for _, row in ipairs(rows) do
      local thread = to_thread(row)
      if thread then threads[#threads + 1] = thread end
    end
    cb(threads, nil, false)
  end)
end

--- Azure DevOps has no draft comments: nothing waits there to be imported
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param cb fun(drafts?: DyReviewDraft[], err?: string)
function M.pending(remote, pull, cb)
  local bad = bad_remote(remote)
  if bad then return cb(nil, bad) end
  if not number(pull) then return cb(nil, 'Not a pull request number') end
  cb({})
end

--- Nothing is ever imported, so no posted draft has an import id
---@param posted string
---@return string?
function M.import_id(posted)
  local _ = posted
  return nil
end

--- `lines` in a plain code block, fenced longer than any run of backticks
--- it holds: Azure DevOps has no suggestion syntax
---@param lines string[]
---@return string
local function fenced(lines)
  local longest = 2
  for _, line in ipairs(lines) do
    for run in line:gmatch('`+') do
      longest = math.max(longest, #run)
    end
  end
  local fence = ('`'):rep(longest + 1)
  return ('%s\n%s\n%s'):format(fence, table.concat(lines, '\n'), fence)
end

--- The text a draft sends: its body, then its suggestion as a code block,
--- and for a file-level comment the line it is about first
---@param draft DyReviewDraft
---@return string
local function body_of(draft)
  local body = draft.body or ''
  if draft.suggestion then
    local block = fenced(draft.suggestion)
    body = body ~= '' and (body .. '\n\n' .. block) or block
  end
  if draft.file_level then body = ('L%d: %s'):format(draft.line, body) end
  return body
end

--- The thread and comment a forge id names, nil for one naming neither
---@param posted any
---@return integer? thread
---@return integer? comment
local function parse_posted(posted)
  if type(posted) ~= 'string' then return nil end
  local thread, comment = posted:match('^(%d+)/(%d+)$')
  if thread then return tonumber(thread), tonumber(comment) end
  return tonumber(posted:match('^(%d+)$'))
end

---@class DyAzureIteration
---@field id integer The last iteration of the pull request
---@field tracking table<string, integer> Change tracking id by path

--- The last iteration of `pull` and the change tracking id of each file it
--- changes, read whole or not at all
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param on_done fun(iteration?: DyAzureIteration, err?: string)
local function last_iteration(remote, pull, on_done)
  forge.api(
    remote,
    on_pull(remote, pull, 'pullRequestIterations'),
    function(data, err)
      if data == nil then return on_done(nil, err) end
      local rows, rows_err = rows_of(data)
      if not rows then return on_done(nil, rows_err) end
      local last
      for _, row in ipairs(rows) do
        local id = tbl(row) and int(row.id)
        if id and (not last or id > last) then last = id end
      end
      if not last then
        return on_done(nil, 'Azure DevOps answered with no iteration')
      end
      local tracking = {}
      local function page(index, skip)
        local query = {
          ['$top'] = M.CHANGES_PER_PAGE,
          ['$skip'] = skip,
          ['$compareTo'] = 0,
        }
        forge.api(
          remote,
          on_pull(
            remote,
            pull,
            'pullRequestIterationChanges',
            { iterationId = last },
            query
          ),
          function(changes, changes_err)
            if changes == nil then return on_done(nil, changes_err) end
            local entries = tbl(changes) and tbl(changes.changeEntries)
            if not entries then
              return on_done(nil, 'Azure DevOps answered with no changes')
            end
            for _, entry in ipairs(entries) do
              local item = tbl(entry) and tbl(entry.item)
              local file = item and text(item.path)
              local id = tbl(entry) and int(entry.changeTrackingId)
              if file and id then tracking[(file:gsub('^/', ''))] = id end
            end
            local next_skip = int(changes.nextSkip) or 0
            if next_skip <= 0 then
              return on_done({ id = last, tracking = tracking })
            end
            -- A file on a page never read could not be commented on
            if index >= M.MAX_PAGES then
              return on_done(
                nil,
                'More changed files than can be read on Azure DevOps'
              )
            end
            page(index + 1, next_skip)
          end
        )
      end
      page(1, 0)
    end
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

--- A draft as a new thread on its file, or why it cannot be one
---
--- A line goes on the right file (new side) or the left (old side); a
--- file-level comment names the file alone, and its line in its text.
---@param iteration DyAzureIteration
---@param draft DyReviewDraft
---@return table? input
---@return string? err
local function thread_input(iteration, draft)
  local tracking = iteration.tracking[draft.path]
  if not tracking then
    return nil, ("%s is not in the pull request's changes"):format(draft.path)
  end
  ---@type table<string, any>
  local context = { filePath = '/' .. draft.path }
  if not draft.file_level then
    local side = draft.side == 'old' and 'left' or 'right'
    context[side .. 'FileStart'] =
      { line = range_start(draft) or draft.line, offset = 1 }
    context[side .. 'FileEnd'] = { line = draft.line, offset = 1 }
  end
  return {
    comments = {
      { parentCommentId = 0, content = body_of(draft), commentType = TEXT },
    },
    status = ACTIVE,
    threadContext = context,
    pullRequestThreadContext = {
      changeTrackingId = tracking,
      iterationContext = {
        firstComparingIteration = 1,
        secondComparingIteration = iteration.id,
      },
    },
  }
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

--- My vote on `pull`, 0 when I am no reviewer of it
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param me string
---@param on_done fun(vote?: integer, err?: string)
local function my_vote(remote, pull, me, on_done)
  forge.api(
    remote,
    on_pull(remote, pull, 'pullRequestReviewers'),
    function(data, err)
      if data == nil then return on_done(nil, err) end
      local rows, rows_err = rows_of(data)
      if not rows then return on_done(nil, rows_err) end
      for _, reviewer in ipairs(rows) do
        if is_me(reviewer, me) then return on_done(int(reviewer.vote) or 0) end
      end
      on_done(0)
    end
  )
end

---@class DyReviewAzureSend
---@field threads DyReviewDraft[]   new threads on a file
---@field replies DyReviewDraft[]   replies to a thread
---@field resolves DyReviewDraft[]  threads to resolve, after the replies
---@field replied table<DyReviewDraft, boolean> Resolves whose draft is reported by its reply
---@field body? string              a thread on the pull request
---@field vote integer
---@field now integer               my vote as it stands
---@field me string

--- Send a checked review of `pull`: each new thread and reply, reported
--- once it is on Azure DevOps, then the resolutions, the body as a thread,
--- and the vote last
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param plan DyReviewAzureSend
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param on_done fun(err?: string)
local function send(remote, pull, plan, progress, on_done)
  ---@type table<DyReviewDraft, table>
  local inputs = {}
  local function add(draft, next)
    forge.write(
      remote,
      'POST',
      on_pull(remote, pull, 'pullRequestThreads'),
      inputs[draft],
      function(data, err)
        if data == nil then return next(err) end
        local id = tbl(data) and int(data.id)
        if not id then return next('Azure DevOps created no thread') end
        progress(draft, tostring(id))
        next()
      end
    )
  end
  local function reply(draft, next)
    local thread = draft.reply_to --[[@as string]]
    forge.write(
      remote,
      'POST',
      on_pull(remote, pull, 'pullRequestThreadComments', { threadId = thread }),
      -- Under the thread's first comment, as the web answers
      { content = body_of(draft), parentCommentId = 1, commentType = TEXT },
      function(data, err)
        if data == nil then return next(err) end
        local id = tbl(data) and int(data.id)
        if not id then return next('Azure DevOps created no comment') end
        progress(draft, ('%s/%d'):format(thread, id))
        next()
      end
    )
  end
  local function resolve(draft, next)
    forge.write(
      remote,
      'PATCH',
      on_pull(remote, pull, 'pullRequestThreads', {
        threadId = draft.reply_to --[[@as string]],
      }),
      { status = 'fixed' },
      function(data, err)
        if data == nil then return next(err) end
        if not plan.replied[draft] then progress(draft, draft.reply_to) end
        next()
      end
    )
  end
  local function body(next)
    if not plan.body or plan.body == '' then return next() end
    forge.write(remote, 'POST', on_pull(remote, pull, 'pullRequestThreads'), {
      comments = {
        { parentCommentId = 0, content = plan.body, commentType = TEXT },
      },
      status = ACTIVE,
    }, function(data, err) next(data == nil and err or nil) end)
  end
  local function vote(next)
    if plan.now == plan.vote then return next() end
    forge.write(
      remote,
      'PUT',
      on_pull(remote, pull, 'pullRequestReviewers', { reviewerId = plan.me }),
      { id = plan.me, vote = plan.vote },
      function(data, err) next(data == nil and err or nil) end
    )
  end
  local function write_all()
    in_turn(plan.threads, add, function(add_err)
      if add_err then return on_done(add_err) end
      in_turn(plan.replies, reply, function(reply_err)
        if reply_err then return on_done(reply_err) end
        in_turn(plan.resolves, resolve, function(resolve_err)
          if resolve_err then return on_done(resolve_err) end
          body(function(body_err)
            if body_err then return on_done(body_err) end
            vote(on_done)
          end)
        end)
      end)
    end)
  end
  if #plan.threads == 0 then return write_all() end
  -- Every thread's input, built before the first write: a draft that
  -- cannot be placed stops the submit while nothing is sent
  last_iteration(remote, pull, function(iteration, err)
    if not iteration then return on_done(err) end
    for _, draft in ipairs(plan.threads) do
      local input, input_err = thread_input(iteration, draft)
      if not input then return on_done(input_err) end
      inputs[draft] = input
    end
    write_all()
  end)
end

--- Whether `rows` hold a thread of mine on the pull request itself whose
--- text is `body`
---@param rows table[]
---@param me string
---@param body string
---@return boolean
local function body_out(rows, me, body)
  for _, row in ipairs(rows) do
    local first = live_comments(row)[1]
    if
      row.isDeleted ~= true
      and not tbl(row.threadContext)
      and first
      and is_me(first.author, me)
      and first.content == body
    then
      return true
    end
  end
  return false
end

--- Send `drafts` with `review`'s vote and text
---
--- Each new draft becomes a thread, or a comment in the thread it answers,
--- reported through `progress` as soon as Azure DevOps has it, so a submit
--- cut short and run again never adds it twice; a draft already `posted` is
--- never sent. Then threads are resolved, a body posted as a thread of its
--- own (Azure DevOps has no review text), and my vote set last. A failed
--- call stops the submit there and is never tried again here: one that
--- timed out may still have reached Azure DevOps.
---
--- Refused before any write: drafts sent before whose thread or comment is
--- gone, named in `info.lost`, which only the caller may send again. With
--- nothing new, the threads are only resolved when the vote and body asked
--- for are already out (`info.already`, the vote) or would make an empty
--- review (`info.skipped`).
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param drafts DyReviewDraft[]
---@param review { verdict: string, body?: string }
---@param progress fun(draft: DyReviewDraft, forge_id: string)
---@param cb fun(err?: string, info?: { lost?: string[], already?: integer, skipped?: string })
function M.submit(remote, pull, drafts, review, progress, cb)
  local verdict = type(review) == 'table' and review.verdict
  local want = M.VOTES[verdict]
  if not want then
    return cb('Azure DevOps has no verdict ' .. tostring(verdict))
  end
  local bad = bad_remote(remote)
  if bad then return cb(bad) end
  if not number(pull) then return cb('Not a pull request number') end
  ---@type DyReviewAzureSend
  local plan = {
    threads = {},
    replies = {},
    resolves = {},
    replied = {},
    body = review.body,
    vote = want,
    now = 0,
    me = '',
  }
  local sent = {}
  for _, draft in ipairs(drafts) do
    if draft.posted then
      local thread, comment = parse_posted(draft.posted)
      if thread then
        sent[#sent + 1] = { draft = draft, thread = thread, comment = comment }
      end
    elseif draft.reply_to then
      if
        type(draft.reply_to) ~= 'string' or not draft.reply_to:match('^%d+$')
      then
        return cb('Not a thread of Azure DevOps: ' .. tostring(draft.reply_to))
      end
      if body_of(draft) ~= '' then
        table.insert(plan.replies, draft)
        if draft.resolve then
          table.insert(plan.resolves, draft)
          plan.replied[draft] = true
        end
      elseif draft.resolve then
        table.insert(plan.resolves, draft)
      end
    else
      table.insert(plan.threads, draft)
    end
  end
  ---@param info table
  local function resolve_only(info)
    plan.threads, plan.replies, plan.body = {}, {}, nil
    plan.vote = plan.now
    send(remote, pull, plan, progress, function(err)
      if err then return cb(err) end
      cb(nil, info)
    end)
  end
  whoami(remote, function(me, me_err)
    if not me then return cb(me_err) end
    plan.me = me
    all_threads(remote, pull, function(rows, rows_err)
      if not rows then return cb(rows_err) end
      local by_id = {}
      for _, row in ipairs(rows) do
        by_id[row.id] = row
      end
      local lost = {}
      for _, item in ipairs(sent) do
        local row = by_id[item.thread]
        local there = row ~= nil and row.isDeleted ~= true
        if there and item.comment then
          there = false
          for _, comment in ipairs(live_comments(row)) do
            if comment.id == item.comment then there = true end
          end
        end
        if not there then
          lost[#lost + 1] = item.draft.id
        elseif
          item.comment
          and item.draft.resolve
          and item.draft.reply_to == tostring(item.thread)
          and row.status == 'active'
        then
          -- Its reply went out but the thread was never resolved
          table.insert(plan.resolves, item.draft)
          plan.replied[item.draft] = true
        end
      end
      if #lost > 0 then
        return cb(
          #lost == 1 and '1 draft was deleted on Azure DevOps'
            or ('%d drafts were deleted on Azure DevOps'):format(#lost),
          { lost = lost }
        )
      end
      local has_body = review.body ~= nil and review.body ~= ''
      local out = has_body and body_out(rows, me, review.body --[[@as string]])
      -- A submit that timed out after the body went out
      if out then plan.body = nil end
      my_vote(remote, pull, me, function(now, vote_err)
        if not now then return cb(vote_err) end
        plan.now = now
        local nothing_new = #plan.threads == 0 and #plan.replies == 0
        if nothing_new and now == want and (not has_body or out) then
          if verdict ~= 'no_vote' or out or #sent > 0 then
            return resolve_only({ already = want })
          end
          return resolve_only({ skipped = 'empty comment review' })
        end
        send(remote, pull, plan, progress, cb)
      end)
    end)
  end)
end

--- Azure DevOps has no suggested change: a suggestion goes as a plain code
--- block in the comment's text
---@param lines string[]
---@return string?
function M.suggestion(lines)
  local _ = lines
  return nil
end

return M
