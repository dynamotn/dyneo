local h = require('helpers')

local FIXTURES = h.root .. '/tests/fixtures/review/github/'

describe('tools.review.forge.github', function()
  local github, dir, cleanup, path
  local remote = { kind = 'github', host = 'github.com', slug = 'o/r' }
  remote.name = 'origin'

  --- The fake `gh`: it records each call's arguments and input, and answers
  --- from `answers/<key>.json`, the key being the endpoint with every other
  --- character an underscore, and for GraphQL the operation's name and the
  --- cursor asked for. A `<key>.code` file makes it fail with that code.
  local FAKE = [[
#!/bin/sh
d="%s"
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/count"
for last; do :; done
printf '%%s\n' "$@" > "$d/calls/$n.args"
case " $* " in
  *" --input "*) cat > "$d/calls/$n.stdin" ;;
  *) : > "$d/calls/$n.stdin" ;;
esac
key=$(printf '%%s' "$last" | tr -c 'A-Za-z0-9' '_')
if [ "$last" = graphql ]; then
  op=$(sed -nE 's/.*(query|mutation) (Dy[A-Za-z]+).*/\2/p' "$d/calls/$n.stdin")
  cur=$(grep -o '"cursor":"[^"]*"' "$d/calls/$n.stdin" | sed 's/.*:"//; s/"$//')
  key="graphql_${op}${cur:+_$cur}"
fi
echo "$key" > "$d/calls/$n.key"
if [ -f "$d/answers/$key.code" ]; then
  echo "HTTP 502 for $key" >&2
  exit "$(cat "$d/answers/$key.code")"
fi
if [ -f "$d/answers/$key.json" ]; then cat "$d/answers/$key.json"; exit 0; fi
echo "no answer for $key" >&2
exit 1
]]

  before_each(function()
    h.unload('tools.review.forge.github', 'util.forge')
    github = require('tools.review.forge.github')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/calls', 'p')
    vim.fn.mkdir(dir .. '/answers', 'p')
    h.write(dir .. '/bin/gh', vim.split(FAKE:format(dir), '\n'))
    vim.fn.setfperm(dir .. '/bin/gh', 'rwxr-xr-x')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
  end)

  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  --- Make the fake answer `key` with a fixture's name, a table as JSON, raw
  --- text, or `{ code = n }` for a failure
  ---@param key string
  ---@param value string|table
  local function answer(key, value)
    local file = dir .. '/answers/' .. key
    if type(value) == 'string' and value:match('%.json$') then
      vim.fn.writefile(vim.fn.readfile(FIXTURES .. value), file .. '.json')
    elseif type(value) == 'string' then
      vim.fn.writefile({ value }, file .. '.json')
    elseif value.code then
      vim.fn.writefile({ tostring(value.code) }, file .. '.code')
    else
      vim.fn.writefile({ vim.json.encode(value) }, file .. '.json')
    end
  end

  --- Every call the fake answered, in order: its key, arguments and input
  ---@return { key: string, args: string[], body: any }[]
  local function calls()
    local list = {}
    local count = 0
    if vim.uv.fs_stat(dir .. '/count') then
      count = tonumber(vim.fn.readfile(dir .. '/count')[1]) or 0
    end
    for n = 1, count do
      local base = ('%s/calls/%d'):format(dir, n)
      local stdin = table.concat(vim.fn.readfile(base .. '.stdin'), '\n')
      list[n] = {
        key = vim.fn.readfile(base .. '.key')[1],
        args = vim.fn.readfile(base .. '.args'),
        body = stdin ~= '' and vim.json.decode(stdin) or nil,
      }
    end
    return list
  end

  --- The keys of every call, in order
  ---@return string[]
  local function keys()
    return vim.tbl_map(function(call) return call.key end, calls())
  end

  --- Run `fn(cb)` and wait for what it hands `cb`
  ---@param fn fun(cb: fun(...))
  ---@return any ...
  local function wait(fn)
    local done, result = false, nil
    fn(function(...)
      done, result = true, vim.F.pack_len(...)
    end)
    assert.is_true(vim.wait(10000, function() return done end, 5))
    return vim.F.unpack_len(result)
  end

  --- A pull request as the REST API lists it
  ---@param number integer
  ---@return table
  local function raw_pull(number)
    return {
      number = number,
      state = 'open',
      title = 't' .. number,
      html_url = 'u',
      user = { login = 'x' },
      requested_reviewers = {},
      base = { ref = 'main', sha = 'b', repo = { full_name = 'o/r' } },
      head = { ref = 'h', sha = 'a', repo = { full_name = 'o/r' } },
    }
  end

  --- A full page of pull requests, numbered from `first`
  ---@param first integer
  ---@return table[]
  local function full_page(first)
    local rows = {}
    for i = 0, github.PER_PAGE - 1 do
      rows[#rows + 1] = raw_pull(first + i)
    end
    return rows
  end

  local PULLS = 'repos_o_r_pulls_state_open_per_page_100_page_'

  describe('list', function()
    it('reads open pull requests and whether my review is asked', function()
      answer('user', 'user.json')
      answer(PULLS .. '1', 'pulls.json')
      local pulls, err, capped = wait(function(cb) github.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_false(capped)
      assert.equals(2, #pulls)
      assert.same({
        id = '7',
        title = 'Add a parser',
        author = 'alice',
        body = 'Parses things.',
        url = 'https://github.com/o/r/pull/7',
        base_ref = 'main',
        head_ref = 'parser',
        base_sha = 'b7b7b7',
        head_sha = 'a7a7a7',
        fetch = {
          '+refs/pull/7/head:refs/dyneo/review/github-7/head',
          '+refs/heads/main:refs/dyneo/review/github-7/base',
        },
        fork = false,
        requested = true,
      }, pulls[1])
      assert.equals('', pulls[2].body)
      assert.is_true(pulls[2].fork)
      assert.is_false(pulls[2].requested)
      assert.same(
        { 'api', '--hostname', 'github.com', 'user' },
        calls()[1].args
      )
    end)

    it('asks who I am once per session and host', function()
      answer('user', 'user.json')
      answer(PULLS .. '1', 'pulls.json')
      wait(function(cb) github.list(remote, cb) end)
      wait(function(cb) github.list(remote, cb) end)
      assert.same({ 'user', PULLS .. '1', PULLS .. '1' }, keys())
    end)

    it('reads every page', function()
      answer('user', 'user.json')
      answer(PULLS .. '1', full_page(1))
      answer(PULLS .. '2', 'pulls.json')
      local pulls, err, capped = wait(function(cb) github.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_false(capped)
      assert.equals(102, #pulls)
    end)

    it('fails the whole listing when a page fails', function()
      answer('user', 'user.json')
      answer(PULLS .. '1', full_page(1))
      answer(PULLS .. '2', { code = 1 })
      local pulls, err = wait(function(cb) github.list(remote, cb) end)
      assert.is_nil(pulls)
      assert.matches('502', err)
    end)

    it('fails the whole listing when a page is cut short', function()
      answer('user', 'user.json')
      answer(PULLS .. '1', full_page(1))
      answer(PULLS .. '2', '[{"number": 1, "tit')
      local pulls, err = wait(function(cb) github.list(remote, cb) end)
      assert.is_nil(pulls)
      assert.is_string(err)
    end)

    it('says when it stopped at the last page it reads', function()
      answer('user', 'user.json')
      for page = 1, github.MAX_PAGES + 1 do
        answer(PULLS .. page, full_page((page - 1) * github.PER_PAGE + 1))
      end
      local pulls, err, capped = wait(function(cb) github.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_true(capped)
      assert.equals(github.MAX_PAGES * github.PER_PAGE, #pulls)
      assert.equals(github.MAX_PAGES + 1, #calls())
    end)

    it('fails when it cannot tell who I am', function()
      answer('user', { code = 4 })
      local pulls, err = wait(function(cb) github.list(remote, cb) end)
      assert.is_nil(pulls)
      assert.is_string(err)
      assert.same({ 'user' }, keys())
    end)
  end)

  describe('for_branch', function()
    local KEY = 'repos_o_r_pulls_state_open_head_o_3Afeat_2Fx_per_page_1'

    it('finds the open pull request of a branch', function()
      answer(KEY, { raw_pull(5) })
      local pull, err = wait(
        function(cb) github.for_branch(remote, 'feat/x', cb) end
      )
      assert.is_nil(err)
      assert.equals('5', pull.id)
      assert.same({ KEY }, keys())
    end)

    it('hands nil without an error when the branch has none', function()
      answer(KEY, {})
      local pull, err = wait(
        function(cb) github.for_branch(remote, 'feat/x', cb) end
      )
      assert.is_nil(pull)
      assert.is_nil(err)
    end)
  end)

  describe('get', function()
    it('reads one pull request, read-only once merged', function()
      answer('repos_o_r_pulls_12', 'pull.json')
      local pull, err = wait(function(cb) github.get(remote, '12', cb) end)
      assert.is_nil(err)
      assert.equals('a12', pull.head_sha)
      assert.equals('b12', pull.base_sha)
      assert.equals('release/1.0', pull.base_ref)
      -- A deleted fork has no repository: still a fork
      assert.is_true(pull.fork)
      assert.matches('merged', pull.read_only)
    end)

    it('refuses an id that is not a number, asking nothing', function()
      local pull, err = wait(function(cb) github.get(remote, '1/../x', cb) end)
      assert.is_nil(pull)
      assert.is_string(err)
      assert.same({}, calls())
    end)

    it('keeps a branch that would bend a refspec out of the fetch', function()
      local raw = raw_pull(3)
      raw.base.ref = 'a:refs/heads/main'
      answer('repos_o_r_pulls_3', raw)
      local pull = wait(function(cb) github.get(remote, '3', cb) end)
      assert.same(
        { '+refs/pull/3/head:refs/dyneo/review/github-3/head' },
        pull.fetch
      )
    end)
  end)

  describe('threads', function()
    local pull = { id = '7', head_sha = 'a7a7a7', base_sha = 'b7b7b7' }

    it('reads every thread through GraphQL', function()
      answer('graphql_DyReviewThreads', 'threads-1.json')
      answer('graphql_DyReviewThreads_c1', 'threads-2.json')
      local threads, err, capped = wait(
        function(cb) github.threads(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.is_false(capped)
      assert.same({
        {
          id = 'PRRT_1',
          path = 'a.lua',
          side = 'new',
          line = 10,
          start_line = 8,
          resolved = false,
          comments = {
            {
              author = 'alice',
              body = 'Why?',
              time = '2026-10-01T10:00:00Z',
            },
            {
              author = 'ghost',
              body = 'Because.',
              time = '2026-10-01T11:00:00Z',
            },
          },
        },
        {
          id = 'PRRT_2',
          path = 'b.lua',
          side = 'old',
          line = 4,
          resolved = true,
          comments = {
            {
              author = 'bob',
              body = 'Gone now.',
              time = '2026-10-02T10:00:00Z',
            },
          },
        },
        {
          id = 'PRRT_3',
          path = 'c.lua',
          side = 'new',
          resolved = false,
          comments = {
            {
              author = 'carol',
              body = 'Whole file.',
              time = '2026-10-03T10:00:00Z',
            },
          },
        },
      }, threads)
      local body = calls()[1].body
      assert.same({ owner = 'o', name = 'r', number = 7 }, body.variables)
      assert.matches('reviewThreads', body.query)
      assert.equals('c1', calls()[2].body.variables.cursor)
    end)

    it('says when it stopped at the last page it reads', function()
      github.MAX_PAGES = 1
      answer('graphql_DyReviewThreads', 'threads-1.json')
      local threads, err, capped = wait(
        function(cb) github.threads(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.is_true(capped)
      assert.equals(1, #threads)
      assert.equals(1, #calls())
    end)

    it('fails on a GraphQL error', function()
      answer('graphql_DyReviewThreads', {
        data = vim.NIL,
        errors = { { message = 'Could not resolve to a PullRequest' } },
      })
      local threads, err = wait(
        function(cb) github.threads(remote, pull, cb) end
      )
      assert.is_nil(threads)
      assert.matches('Could not resolve', err)
    end)

    it('fails the whole listing when a later page fails', function()
      answer('graphql_DyReviewThreads', 'threads-1.json')
      answer('graphql_DyReviewThreads_c1', { code = 1 })
      local threads, err = wait(
        function(cb) github.threads(remote, pull, cb) end
      )
      assert.is_nil(threads)
      assert.is_string(err)
    end)
  end)

  describe('pending', function()
    local pull = { id = '7', head_sha = 'a7a7a7', base_sha = 'b7b7b7' }
    local REVIEWS = 'repos_o_r_pulls_7_reviews_per_page_100_page_1'
    local COMMENTS =
      'repos_o_r_pulls_7_reviews_302_comments_per_page_100_page_1'

    it('imports the comments of my pending review as drafts', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, 'review-comments.json')
      local drafts, err = wait(
        function(cb) github.pending(remote, pull, cb) end
      )
      assert.is_nil(err)
      local id = function(n) return vim.fn.sha256('github:' .. n):sub(1, 12) end
      assert.same({
        {
          id = id(501),
          origin = 'forge',
          state = 'ready',
          path = 'a.lua',
          side = 'new',
          line = 12,
          start_line = 10,
          body = 'A range.',
        },
        {
          id = id(502),
          origin = 'forge',
          state = 'ready',
          path = 'b.lua',
          side = 'old',
          line = 3,
          body = 'Old side, outdated.',
        },
        {
          id = id(503),
          origin = 'forge',
          state = 'ready',
          path = 'c.lua',
          side = 'new',
          line = 40,
          body = 'L40: Outside a hunk.',
          file_level = true,
        },
      }, drafts)
      -- The same import gives the same ids
      local again = wait(function(cb) github.pending(remote, pull, cb) end)
      assert.same(drafts, again)
    end)

    it('imports nothing when I have no pending review', function()
      answer('user', 'user.json')
      -- Someone else's pending review and my submitted one
      answer(REVIEWS, {
        { id = 300, node_id = 'A', state = 'PENDING', user = { login = 'x' } },
        {
          id = 301,
          node_id = 'B',
          state = 'COMMENTED',
          user = { login = 'me' },
        },
      })
      local drafts, err = wait(
        function(cb) github.pending(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.same({}, drafts)
    end)

    it('fails when the pending review cannot be read whole', function()
      github.MAX_PAGES = 1
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      local many = {}
      for i = 1, github.PER_PAGE do
        many[i] = { id = i, path = 'a', line = 1, side = 'RIGHT', body = 'x' }
      end
      answer(COMMENTS, many)
      local drafts, err = wait(
        function(cb) github.pending(remote, pull, cb) end
      )
      assert.is_nil(drafts)
      assert.is_string(err)
    end)
  end)

  describe('submit', function()
    local pull = { id = '7', head_sha = 'a7a7a7', base_sha = 'b7b7b7' }
    local REVIEWS = 'repos_o_r_pulls_7_reviews_per_page_100_page_1'
    local COMMENTS =
      'repos_o_r_pulls_7_reviews_302_comments_per_page_100_page_1'
    local CHANGED = 'the pending review on GitHub no longer matches the '
      .. 'drafts here; open the pull request again'
    --- My review 301, submitted long ago
    local SUBMITTED = {
      id = 301,
      node_id = 'PRR_301',
      state = 'COMMENTED',
      user = { login = 'me' },
    }

    --- A draft with `fields` over a plain one on the new side
    ---@param fields table
    ---@return DyReviewDraft
    local function draft(fields)
      return vim.tbl_extend('force', {
        id = fields.id or 'd',
        origin = 'user',
        state = 'ready',
        path = 'a.lua',
        side = 'new',
        line = 1,
        body = 'text',
      }, fields)
    end

    --- A draft imported from forge comment `n`
    ---@param n integer
    ---@return DyReviewDraft
    local function imported(n)
      return draft({
        id = vim.fn.sha256('github:' .. n):sub(1, 12),
        origin = 'forge',
      })
    end

    --- Submit `drafts` with `review` and hand back the error and every
    --- `progress` report, as `{ draft id, forge id }`, and what came with
    --- the error
    local function submit(drafts, review)
      local reports = {}
      local err, info = wait(function(cb)
        github.submit(
          remote,
          pull,
          drafts,
          review,
          function(d, forge_id) table.insert(reports, { d.id, forge_id }) end,
          cb
        )
      end)
      return err, reports, info
    end

    --- The GraphQL inputs of every call, in order
    local function inputs()
      return vim.tbl_map(
        function(call) return call.body and call.body.variables.input end,
        calls()
      )
    end

    --- Answer every write of a submit that succeeds
    local function writes_succeed()
      answer('graphql_DyReviewPullId', 'pull-id.json')
      answer('graphql_DyReviewCreate', 'create-review.json')
      answer('graphql_DyReviewResolve', 'resolve.json')
      answer('graphql_DyReviewAddThread', 'add-thread.json')
      answer('graphql_DyReviewReply', 'reply.json')
      answer('graphql_DyReviewSubmit', 'submit-review.json')
    end

    it('fills one new pending review, then submits it last', function()
      answer('user', 'user.json')
      answer(REVIEWS, { SUBMITTED })
      writes_succeed()
      local err, reports = submit({
        draft({ id = 'line', path = 'a.lua', line = 3, body = 'One line.' }),
        draft({
          id = 'range',
          path = 'a.lua',
          start_line = 5,
          line = 8,
          body = 'A range.',
          suggestion = { 'x = 1', 'y = 2' },
        }),
        draft({
          id = 'old',
          path = 'b.lua',
          side = 'old',
          line = 2,
          body = 'Was.',
        }),
        draft({
          id = 'file',
          path = 'c.lua',
          line = 40,
          body = 'Outside.',
          file_level = true,
        }),
        draft({ id = 'reply', reply_to = 'PRRT_1', body = 'Agreed.' }),
        draft({
          id = 'resolve',
          reply_to = 'PRRT_2',
          body = '',
          resolve = true,
        }),
        draft({ id = 'done', posted = '301/5', body = 'Sent before.' }),
      }, { verdict = 'request_changes', body = 'Summary.' })
      assert.is_nil(err)
      assert.same({
        'user',
        REVIEWS,
        'graphql_DyReviewPullId',
        'graphql_DyReviewCreate',
        'graphql_DyReviewResolve',
        'graphql_DyReviewAddThread',
        'graphql_DyReviewAddThread',
        'graphql_DyReviewAddThread',
        'graphql_DyReviewAddThread',
        'graphql_DyReviewReply',
        'graphql_DyReviewSubmit',
      }, keys())
      local list = inputs()
      assert.same(
        { owner = 'o', name = 'r', number = 7 },
        calls()[3].body.variables
      )
      assert.same({ pullRequestId = 'PR_7', commitOID = 'a7a7a7' }, list[4])
      assert.same({ threadId = 'PRRT_2' }, list[5])
      local review = 'PRR_900'
      assert.same({
        pullRequestReviewId = review,
        path = 'a.lua',
        body = 'One line.',
        line = 3,
        side = 'RIGHT',
        subjectType = 'LINE',
      }, list[6])
      assert.same({
        pullRequestReviewId = review,
        path = 'a.lua',
        body = 'A range.\n\n```suggestion\nx = 1\ny = 2\n```',
        startLine = 5,
        startSide = 'RIGHT',
        line = 8,
        side = 'RIGHT',
        subjectType = 'LINE',
      }, list[7])
      assert.same({
        pullRequestReviewId = review,
        path = 'b.lua',
        body = 'Was.',
        line = 2,
        side = 'LEFT',
        subjectType = 'LINE',
      }, list[8])
      assert.same({
        pullRequestReviewId = review,
        path = 'c.lua',
        body = 'L40: Outside.',
        subjectType = 'FILE',
      }, list[9])
      assert.same({
        pullRequestReviewId = review,
        pullRequestReviewThreadId = 'PRRT_1',
        body = 'Agreed.',
      }, list[10])
      assert.same({
        pullRequestReviewId = review,
        event = 'REQUEST_CHANGES',
        body = 'Summary.',
      }, list[11])
      assert.same({
        { 'resolve', 'PRRT_2' },
        { 'line', '900/601' },
        { 'range', '900/601' },
        { 'old', '900/601' },
        { 'file', '900/601' },
        { 'reply', '900/801' },
      }, reports)
    end)

    it('adds to my pending review and submits it', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, 'review-comments.json')
      writes_succeed()
      local err, reports = submit({
        imported(501),
        imported(502),
        imported(503),
        draft({ id = 'new', line = 4, body = 'New.' }),
      }, { verdict = 'approve' })
      assert.is_nil(err)
      assert.same({
        'user',
        REVIEWS,
        COMMENTS,
        'graphql_DyReviewAddThread',
        'graphql_DyReviewSubmit',
      }, keys())
      local list = inputs()
      assert.equals('PRR_302', list[4].pullRequestReviewId)
      assert.same(
        { pullRequestReviewId = 'PRR_302', event = 'APPROVE' },
        list[5]
      )
      assert.same({
        { 'new', '302/601' },
        { imported(501).id, '302/501' },
        { imported(502).id, '302/502' },
        { imported(503).id, '302/503' },
      }, reports)
    end)

    it('refuses a pending review holding a comment never imported', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, 'review-comments.json')
      writes_succeed()
      local err, reports = submit(
        { imported(501), imported(502), draft({ id = 'new' }) },
        { verdict = 'comment' }
      )
      assert.equals(CHANGED, err)
      assert.same({}, reports)
      assert.same({ 'user', REVIEWS, COMMENTS }, keys())
    end)

    it('refuses a pending review missing a comment sent into it', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, 'review-comments.json')
      writes_succeed()
      local err, reports = submit({
        imported(501),
        imported(502),
        imported(503),
        draft({ id = 'gone', posted = '302/999' }),
      }, { verdict = 'comment' })
      assert.equals(CHANGED, err)
      assert.same({}, reports)
      assert.same({ 'user', REVIEWS, COMMENTS }, keys())
    end)

    it('submits the pending review when everything is in it', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, 'review-comments.json')
      writes_succeed()
      local err, reports = submit({
        draft({ id = 'a', posted = '302/501' }),
        draft({ id = 'b', posted = '302/502' }),
        draft({ id = 'c', posted = '302/503' }),
        -- Published long ago in another review
        draft({ id = 'old', posted = '301/5' }),
      }, { verdict = 'comment', body = '' })
      assert.is_nil(err)
      assert.same(
        { 'user', REVIEWS, COMMENTS, 'graphql_DyReviewSubmit' },
        keys()
      )
      assert.same(
        { pullRequestReviewId = 'PRR_302', event = 'COMMENT', body = '' },
        inputs()[4]
      )
      assert.same({}, reports)
    end)

    it('refuses drafts whose pending review is gone', function()
      answer('user', 'user.json')
      answer(REVIEWS, {})
      writes_succeed()
      local err, reports = submit({ imported(501) }, { verdict = 'comment' })
      assert.is_string(err)
      assert.same({}, reports)
      assert.same({ 'user', REVIEWS }, keys())
    end)

    it('only resolves when a comment review would be empty', function()
      answer('user', 'user.json')
      answer(REVIEWS, {})
      writes_succeed()
      local err, reports, info = submit(
        { draft({ id = 'r', reply_to = 'PRRT_2', body = '', resolve = true }) },
        { verdict = 'comment' }
      )
      assert.is_nil(err)
      assert.same({ skipped = 'empty comment review' }, info)
      assert.same({ 'user', REVIEWS, 'graphql_DyReviewResolve' }, keys())
      assert.same({ { 'r', 'PRRT_2' } }, reports)
    end)

    it('refuses drafts sent into a pending review since deleted', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, 'review-comments.json')
      writes_succeed()
      local err, reports, info = submit({
        imported(501),
        imported(502),
        imported(503),
        draft({ id = 'lost1', posted = '555/1' }),
        draft({ id = 'lost2', posted = '555/2' }),
        draft({ id = 'old', posted = '301/5' }),
        draft({ id = 'new' }),
      }, { verdict = 'approve' })
      assert.equals(
        '2 drafts went into a pending review that was deleted on GitHub',
        err
      )
      assert.same({ lost = { 'lost1', 'lost2' } }, info)
      assert.same({}, reports)
      assert.same({ 'user', REVIEWS }, keys())
    end)

    --- My review `id`, out with `state` and `body`
    local function out_review(id, state, body)
      return {
        id = id,
        node_id = 'PRR_' .. id,
        state = state,
        body = body,
        user = { login = 'me' },
      }
    end

    it('sends nothing again when a timed-out submit went out', function()
      answer('user', 'user.json')
      answer(REVIEWS, { out_review(301, 'APPROVED', 'LGTM') })
      writes_succeed()
      local err, reports, info = submit({
        draft({ id = 'a', posted = '301/1' }),
        draft({ id = 'b', posted = '301/2' }),
        draft({ id = 'r', reply_to = 'PRRT_2', body = '', resolve = true }),
      }, { verdict = 'approve', body = 'LGTM' })
      assert.is_nil(err)
      assert.same({ already = 301 }, info)
      assert.same({ { 'r', 'PRRT_2' } }, reports)
      assert.same({ 'user', REVIEWS, 'graphql_DyReviewResolve' }, keys())
    end)

    --- Submit `review` with nothing new after review rows `rows`, and
    --- assert it was sent as a verdict-only review
    local function sent_after(rows, review)
      answer('user', 'user.json')
      answer(REVIEWS, rows)
      writes_succeed()
      local err, reports, info =
        submit({ draft({ id = 'a', posted = '301/1' }) }, review)
      assert.is_nil(err)
      assert.is_nil(info)
      assert.same({}, reports)
      assert.same({
        'user',
        REVIEWS,
        'graphql_DyReviewPullId',
        'graphql_DyReviewCreate',
        'graphql_DyReviewSubmit',
      }, keys())
      return inputs()[5]
    end

    it('sends a later verdict with nothing new', function()
      local input = sent_after(
        { SUBMITTED },
        { verdict = 'approve', body = 'LGTM' }
      )
      assert.same(
        { pullRequestReviewId = 'PRR_900', event = 'APPROVE', body = 'LGTM' },
        input
      )
    end)

    it('sends the same verdict again with another text', function()
      local input = sent_after(
        { out_review(301, 'APPROVED', 'LGTM') },
        { verdict = 'approve', body = 'Ship it' }
      )
      assert.equals('Ship it', input.body)
    end)

    it(
      'sends a verdict matching only an older review',
      function()
        sent_after({
          out_review(301, 'APPROVED', 'LGTM'),
          out_review(305, 'COMMENTED', ''),
        }, { verdict = 'approve', body = 'LGTM' })
      end
    )

    it('only resolves when an empty pending review would go out', function()
      answer('user', 'user.json')
      answer(REVIEWS, 'reviews.json')
      answer(COMMENTS, {})
      writes_succeed()
      local err, reports, info = submit(
        { draft({ id = 'r', reply_to = 'PRRT_2', body = '', resolve = true }) },
        { verdict = 'comment', body = '' }
      )
      assert.is_nil(err)
      assert.same({ skipped = 'empty comment review' }, info)
      assert.same({ { 'r', 'PRRT_2' } }, reports)
      assert.same(
        { 'user', REVIEWS, COMMENTS, 'graphql_DyReviewResolve' },
        keys()
      )
    end)

    it('sends new drafts in a new review after one went out', function()
      answer('user', 'user.json')
      answer(REVIEWS, { SUBMITTED })
      writes_succeed()
      local err, reports = submit({
        draft({ id = 'a', posted = '301/1' }),
        draft({ id = 'new' }),
      }, { verdict = 'approve' })
      assert.is_nil(err)
      assert.same({
        'user',
        REVIEWS,
        'graphql_DyReviewPullId',
        'graphql_DyReviewCreate',
        'graphql_DyReviewAddThread',
        'graphql_DyReviewSubmit',
      }, keys())
      assert.same({ { 'new', '900/601' } }, reports)
    end)

    it('refuses a verdict GitHub does not have, asking nothing', function()
      local err = submit({ draft({}) }, { verdict = 'reject' })
      assert.is_string(err)
      assert.same({}, calls())
    end)

    it('stops at the first failure, keeping what went in', function()
      answer('user', 'user.json')
      answer(REVIEWS, {})
      writes_succeed()
      answer('graphql_DyReviewReply', { code = 1 })
      local err, reports = submit({
        draft({ id = 'line' }),
        draft({ id = 'reply', reply_to = 'PRRT_1' }),
      }, { verdict = 'approve' })
      assert.is_string(err)
      assert.same({ { 'line', '900/601' } }, reports)
      assert.equals('graphql_DyReviewReply', keys()[#calls()])
    end)
  end)

  it(
    'writes a suggestion in a fenced block',
    function()
      assert.equals(
        '```suggestion\na\n\nb\n```',
        github.suggestion({ 'a', '', 'b' })
      )
    end
  )

  it('offers the verdicts GitHub has', function()
    assert.same(
      { 'approve', 'request_changes', 'comment' },
      vim.tbl_map(function(v) return v.id end, github.verdicts)
    )
  end)
end)

describe('tools.review.forge', function()
  it('picks the adapter of a remote', function()
    h.unload('tools.review.forge', 'tools.review.forge.github')
    local forge = require('tools.review.forge')
    assert.equals(
      require('tools.review.forge.github'),
      (forge.for_remote({ kind = 'github', host = 'h', slug = 'o/r' }))
    )
    for _, kind in ipairs({ 'gitlab', 'azure' }) do
      local adapter, err = forge.for_remote({ kind = kind })
      assert.is_nil(adapter)
      assert.equals('not yet supported', err)
    end
  end)
end)
