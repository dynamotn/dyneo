local h = require('helpers')

local FIXTURES = h.root .. '/tests/fixtures/review/gitlab/'

describe('tools.review.forge.gitlab', function()
  local gitlab, dir, cleanup, path
  local remote = { kind = 'gitlab', host = 'gitlab.com', slug = 'g/sub/p' }
  remote.name = 'origin'

  --- The fake `glab`: it records each call's arguments and input, and answers
  --- from `answers/<key>.<n>.json` for the n-th call of that key, else from
  --- `answers/<key>.json`, the key being the endpoint with every other
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
k=$(( $(cat "$d/count.$key" 2>/dev/null || echo 0) + 1 ))
echo "$k" > "$d/count.$key"
if [ -f "$d/answers/$key.$k.code" ] || [ -f "$d/answers/$key.code" ]; then
  echo "HTTP 502 for $key" >&2
  exit 1
fi
if [ -f "$d/answers/$key.$k.json" ]; then cat "$d/answers/$key.$k.json"; exit 0; fi
if [ -f "$d/answers/$key.json" ]; then cat "$d/answers/$key.json"; exit 0; fi
echo "no answer for $key" >&2
exit 1
]]

  before_each(function()
    h.unload('tools.review.forge.gitlab', 'util.forge')
    gitlab = require('tools.review.forge.gitlab')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/calls', 'p')
    vim.fn.mkdir(dir .. '/answers', 'p')
    h.write(dir .. '/bin/glab', vim.split(FAKE:format(dir), '\n'))
    vim.fn.setfperm(dir .. '/bin/glab', 'rwxr-xr-x')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
  end)

  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  --- Make the fake answer `key` with a fixture's name, a table as JSON, raw
  --- text, or `{ code = n }` for a failure
  ---@param key string `<key>` or `<key>.<n>` for the n-th call only
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

  local PROJECT = 'projects_g_2Fsub_2Fp_merge_requests'
  local MR = PROJECT .. '_7'
  local DISCUSSIONS = MR .. '_discussions_per_page_100_page_1'
  local DRAFTS = MR .. '_draft_notes_per_page_100_page_1'
  local NEW_DRAFT = MR .. '_draft_notes'
  local PUBLISH = MR .. '_draft_notes_bulk_publish'
  local APPROVALS = MR .. '_approvals'
  local DIFFS = MR .. '_diffs_per_page_100_page_1'

  --- A merge request node of the GraphQL listing
  ---@param iid integer
  ---@return table
  local function node(iid)
    return {
      iid = tostring(iid),
      title = 't' .. iid,
      webUrl = 'u',
      state = 'opened',
      sourceBranch = 'h',
      targetBranch = 'main',
      sourceProjectId = 3,
      targetProjectId = 3,
      author = { username = 'x' },
      reviewers = { nodes = {} },
      diffRefs = { baseSha = 'b', headSha = 'a', startSha = 's' },
    }
  end

  --- A page of the GraphQL listing, with a next one after it when `cursor`
  ---@param nodes table[]
  ---@param cursor? string
  ---@return table
  local function list_page(nodes, cursor)
    return {
      data = {
        project = {
          mergeRequests = {
            pageInfo = { hasNextPage = cursor ~= nil, endCursor = cursor },
            nodes = nodes,
          },
        },
      },
    }
  end

  describe('list', function()
    it('reads open merge requests and whether my review is asked', function()
      answer('user', 'user.json')
      answer('graphql_DyReviewMergeRequests', 'merge-requests-1.json')
      answer('graphql_DyReviewMergeRequests_c1', 'merge-requests-2.json')
      local pulls, err, capped = wait(function(cb) gitlab.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_false(capped)
      -- One without diff refs yet cannot be reviewed
      assert.equals(2, #pulls)
      assert.same({
        id = '7',
        title = 'Add a parser',
        author = 'alice',
        body = 'Parses things.',
        url = 'https://gitlab.com/g/sub/p/-/merge_requests/7',
        base_ref = 'main',
        head_ref = 'parser',
        base_sha = 'b7b7b7',
        head_sha = 'a7a7a7',
        start_sha = 's7s7s7',
        fetch = {
          '+refs/merge-requests/7/head:refs/dyneo/review/gitlab-7/head',
          '+refs/heads/main:refs/dyneo/review/gitlab-7/base',
        },
        fork = false,
        requested = true,
      }, pulls[1])
      assert.equals('8', pulls[2].id)
      assert.equals('', pulls[2].body)
      assert.equals('ghost', pulls[2].author)
      assert.is_true(pulls[2].fork)
      assert.is_false(pulls[2].requested)
      local first = calls()[2]
      assert.same(
        { 'api', '--hostname', 'gitlab.com', '--method', 'POST' },
        vim.list_slice(first.args, 1, 5)
      )
      assert.same({ path = 'g/sub/p', cursor = nil }, first.body.variables)
      assert.equals('c1', calls()[3].body.variables.cursor)
    end)

    it('asks who I am once per session and host', function()
      answer('user', 'user.json')
      answer('graphql_DyReviewMergeRequests', list_page({ node(1) }))
      wait(function(cb) gitlab.list(remote, cb) end)
      wait(function(cb) gitlab.list(remote, cb) end)
      assert.same({
        'user',
        'graphql_DyReviewMergeRequests',
        'graphql_DyReviewMergeRequests',
      }, keys())
    end)

    it('says when it stopped at the last page it reads', function()
      gitlab.MAX_PAGES = 1
      answer('user', 'user.json')
      answer('graphql_DyReviewMergeRequests', list_page({ node(1) }, 'c1'))
      local pulls, err, capped = wait(function(cb) gitlab.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_true(capped)
      assert.equals(1, #pulls)
      assert.equals(2, #calls())
    end)

    it('fails the whole listing when a page is cut short', function()
      answer('user', 'user.json')
      answer('graphql_DyReviewMergeRequests', list_page({ node(1) }, 'c1'))
      answer('graphql_DyReviewMergeRequests_c1', '{"data": {"proj')
      local pulls, err = wait(function(cb) gitlab.list(remote, cb) end)
      assert.is_nil(pulls)
      assert.is_string(err)
    end)

    it('fails on a GraphQL error', function()
      answer('user', 'user.json')
      answer('graphql_DyReviewMergeRequests', {
        errors = { { message = 'Project not found' } },
      })
      local pulls, err = wait(function(cb) gitlab.list(remote, cb) end)
      assert.is_nil(pulls)
      assert.matches('Project not found', err)
    end)
  end)

  describe('for_branch', function()
    local KEY = PROJECT .. '_state_opened_source_branch_feat_2Fx_per_page_20'

    it('finds the open merge request of a branch of this project', function()
      local fork = { iid = 4, source_project_id = 5, target_project_id = 3 }
      local own = { iid = 7, source_project_id = 3, target_project_id = 3 }
      answer(KEY, { fork, own })
      answer(MR, 'merge-request.json')
      local pull, err = wait(
        function(cb) gitlab.for_branch(remote, 'feat/x', cb) end
      )
      assert.is_nil(err)
      assert.equals('12', pull.id)
      assert.same({ KEY, MR }, keys())
    end)

    it('hands nil without an error when the branch has none', function()
      answer(KEY, {})
      local pull, err = wait(
        function(cb) gitlab.for_branch(remote, 'feat/x', cb) end
      )
      assert.is_nil(pull)
      assert.is_nil(err)
    end)
  end)

  describe('get', function()
    it('reads one merge request, read-only once merged', function()
      answer(PROJECT .. '_12', 'merge-request.json')
      local pull, err = wait(function(cb) gitlab.get(remote, '12', cb) end)
      assert.is_nil(err)
      assert.equals('a12', pull.head_sha)
      assert.equals('b12', pull.base_sha)
      assert.equals('s12', pull.start_sha)
      assert.equals('release/1.0', pull.base_ref)
      assert.is_true(pull.fork)
      assert.matches('merged', pull.read_only)
      assert.same({
        'api',
        '--hostname',
        'gitlab.com',
        'projects/g%2Fsub%2Fp/merge_requests/12',
      }, calls()[1].args)
    end)

    it('refuses an id that is not a number, asking nothing', function()
      local pull, err = wait(function(cb) gitlab.get(remote, '1/../x', cb) end)
      assert.is_nil(pull)
      assert.is_string(err)
      assert.same({}, calls())
    end)

    it('refuses a merge request whose diff is not ready', function()
      answer(PROJECT .. '_3', {
        iid = 3,
        state = 'opened',
        target_branch = 'main',
        diff_refs = vim.NIL,
      })
      local pull, err = wait(function(cb) gitlab.get(remote, '3', cb) end)
      assert.is_nil(pull)
      assert.is_string(err)
    end)
  end)

  describe('threads', function()
    local pull = { id = '7', head_sha = 'a7a7a7', base_sha = 'b7b7b7' }

    it('reads every diff thread', function()
      answer(DISCUSSIONS, 'discussions.json')
      local threads, err, capped = wait(
        function(cb) gitlab.threads(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.is_false(capped)
      assert.same({
        {
          id = 'd1',
          path = 'a.lua',
          side = 'new',
          line = 10,
          start_line = 8,
          resolved = false,
          comments = {
            { author = 'alice', body = 'Why?', time = '2026-10-01T10:00:00Z' },
            {
              author = 'ghost',
              body = 'Because.',
              time = '2026-10-01T11:00:00Z',
            },
          },
        },
        {
          id = 'd2',
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
          id = 'd3',
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
    end)

    it('reads every page and says when it stopped at the last', function()
      gitlab.PER_PAGE = 2
      gitlab.MAX_PAGES = 2
      local function row(id)
        return {
          id = id,
          notes = {
            {
              id = 1,
              body = id,
              author = { username = 'a' },
              position = {
                position_type = 'text',
                new_path = 'a',
                new_line = 1,
              },
            },
          },
        }
      end
      local base = MR .. '_discussions_per_page_2_page_'
      answer(base .. '1', { row('x1'), row('x2') })
      answer(base .. '2', { row('x3'), row('x4') })
      local threads, err, capped = wait(
        function(cb) gitlab.threads(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.is_true(capped)
      assert.equals(4, #threads)
      assert.same({ base .. '1', base .. '2' }, keys())
    end)

    it('fails the whole listing when a page fails', function()
      gitlab.PER_PAGE = 1
      local base = MR .. '_discussions_per_page_1_page_'
      answer(base .. '1', { { id = 'x', notes = {} } })
      answer(base .. '2', { code = 1 })
      local threads, err = wait(
        function(cb) gitlab.threads(remote, pull, cb) end
      )
      assert.is_nil(threads)
      assert.matches('502', err)
    end)
  end)

  --- The id a draft imported from draft note `n` goes by
  ---@param n integer
  ---@return string
  local function forge_id(n) return vim.fn.sha256('gitlab:' .. n):sub(1, 12) end

  describe('pending', function()
    local pull = { id = '7', head_sha = 'a7a7a7', base_sha = 'b7b7b7' }

    it('imports my draft notes as drafts', function()
      answer(DRAFTS, 'draft-notes.json')
      local drafts, err = wait(
        function(cb) gitlab.pending(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.same({
        {
          id = forge_id(61),
          origin = 'forge',
          state = 'ready',
          path = 'a.lua',
          side = 'new',
          line = 12,
          start_line = 10,
          body = 'A range.',
        },
        {
          id = forge_id(62),
          origin = 'forge',
          state = 'ready',
          path = 'b.lua',
          side = 'old',
          line = 3,
          body = 'Old side.',
        },
        {
          id = forge_id(63),
          origin = 'forge',
          state = 'ready',
          path = 'c.lua',
          side = 'new',
          line = 40,
          body = 'L40: Outside a hunk.',
          file_level = true,
        },
        {
          id = forge_id(64),
          origin = 'forge',
          state = 'ready',
          path = '',
          side = 'new',
          line = 1,
          body = 'Agreed.',
          reply_to = 'd1',
          resolve = true,
        },
      }, drafts)
      local again = wait(function(cb) gitlab.pending(remote, pull, cb) end)
      assert.same(drafts, again)
    end)

    it('fails when the draft notes cannot be read whole', function()
      gitlab.MAX_PAGES = 1
      gitlab.PER_PAGE = 1
      answer(MR .. '_draft_notes_per_page_1_page_1', { { id = 1, note = 'x' } })
      local drafts, err = wait(
        function(cb) gitlab.pending(remote, pull, cb) end
      )
      assert.is_nil(drafts)
      assert.is_string(err)
    end)
  end)

  describe('submit', function()
    local pull = {
      id = '7',
      head_sha = 'a7a7a7',
      base_sha = 'b7b7b7',
      start_sha = 's7s7s7',
    }
    local CHANGED = 'the pending review on GitLab no longer matches the '
      .. 'drafts here; open the merge request again'
    local POSITION = {
      base_sha = 'b7b7b7',
      start_sha = 's7s7s7',
      head_sha = 'a7a7a7',
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

    --- A draft imported from draft note `n`
    ---@param n integer
    ---@return DyReviewDraft
    local function imported(n)
      return draft({ id = forge_id(n), origin = 'forge' })
    end

    --- Submit `drafts` with `review` and hand back the error, every
    --- `progress` report as `{ draft id, forge id }`, and the info
    local function submit(drafts, review)
      local reports = {}
      local err, info = wait(function(cb)
        gitlab.submit(
          remote,
          pull,
          drafts,
          review,
          function(d, id) table.insert(reports, { d.id, id }) end,
          cb
        )
      end)
      return err, reports, info
    end

    --- My draft note `id`, or a note of mine in a discussion
    local function mine(id, body, extra)
      return vim.tbl_extend(
        'force',
        { id = id, note = body, body = body, author = { id = 42 } },
        extra or {}
      )
    end

    --- Answer every read and write of a submit that succeeds; draft notes
    --- are numbered from 900 on
    local function writes_succeed()
      answer(DIFFS, 'diffs.json')
      for n = 1, 9 do
        answer(NEW_DRAFT .. '.' .. n, { id = 899 + n })
      end
      answer(PUBLISH, '')
      answer(MR .. '_discussions_d2_resolved_true', { id = 'd2' })
      answer(MR .. '_notes', { id = 777 })
      answer(MR .. '_approve', { approved = true })
      answer(MR .. '_unapprove', { approved = false })
      answer(APPROVALS, { user_has_approved = false })
    end

    --- SHA-1 of `a.lua`, as `sha1sum` gives it
    local A = 'bf6d65a69d79ae89a55de1c2b09b3f98b96d6d36'

    it('creates every draft note, publishes them, then the verdict', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      writes_succeed()
      local err, reports, info = submit({
        draft({ id = 'line', line = 3, body = 'One line.' }),
        draft({
          id = 'range',
          start_line = 5,
          line = 8,
          body = 'A range.',
          suggestion = { 'x = 1', 'y = ```z```' },
        }),
        draft({ id = 'added', line = 4 }),
        draft({ id = 'old', path = 'b.lua', side = 'old', line = 2 }),
        draft({
          id = 'file',
          path = 'c.lua',
          line = 40,
          body = 'Outside.',
          file_level = true,
        }),
        draft({ id = 'outside', path = 'c.lua', line = 50 }),
        draft({ id = 'reply', reply_to = 'd1', body = 'Agreed.' }),
        draft({
          id = 'both',
          reply_to = 'd3',
          body = 'Fixed.',
          resolve = true,
        }),
        draft({ id = 'resolve', reply_to = 'd2', body = '', resolve = true }),
      }, { verdict = 'approve', body = 'Summary.' })
      assert.is_nil(err)
      -- The body note's id: the mark a later round's body is matched past
      assert.same({ mark = 777 }, info)
      assert.same({
        'user',
        DRAFTS,
        DIFFS,
        NEW_DRAFT,
        NEW_DRAFT,
        NEW_DRAFT,
        NEW_DRAFT,
        NEW_DRAFT,
        NEW_DRAFT,
        NEW_DRAFT,
        NEW_DRAFT,
        PUBLISH,
        MR .. '_discussions_d2_resolved_true',
        MR .. '_notes',
        APPROVALS,
        MR .. '_approve',
      }, keys())
      local list = calls()
      -- An unchanged line names both sides
      assert.same({
        note = 'One line.',
        position = vim.tbl_extend('force', POSITION, {
          position_type = 'text',
          old_path = 'a.lua',
          new_path = 'a.lua',
          old_line = 3,
          new_line = 3,
        }),
      }, list[4].body)
      assert.same({
        note = 'A range.\n\n````suggestion:-3+0\nx = 1\ny = ```z```\n````',
        position = vim.tbl_extend('force', POSITION, {
          position_type = 'text',
          old_path = 'a.lua',
          new_path = 'a.lua',
          old_line = 6,
          new_line = 8,
          line_range = {
            start = { line_code = A .. '_5_5', type = 'new', new_line = 5 },
            ['end'] = {
              line_code = A .. '_6_8',
              type = 'old',
              old_line = 6,
              new_line = 8,
            },
          },
        }),
      }, list[5].body)
      -- An added line names the new side only
      assert.same({
        position_type = 'text',
        old_path = 'a.lua',
        new_path = 'a.lua',
        new_line = 4,
      }, {
        position_type = list[6].body.position.position_type,
        old_path = list[6].body.position.old_path,
        new_path = list[6].body.position.new_path,
        old_line = list[6].body.position.old_line,
        new_line = list[6].body.position.new_line,
      })
      -- A removed line of a renamed file: the old side and the old path
      assert.same({
        note = 'text',
        position = vim.tbl_extend('force', POSITION, {
          position_type = 'text',
          old_path = 'b_old.lua',
          new_path = 'b.lua',
          old_line = 2,
        }),
      }, list[7].body)
      assert.same({
        note = 'L40: Outside.',
        position = vim.tbl_extend('force', POSITION, {
          position_type = 'file',
          old_path = 'c.lua',
          new_path = 'c.lua',
        }),
      }, list[8].body)
      -- A line in no hunk goes on the file, naming the line
      assert.same({
        note = 'L50: text',
        position = vim.tbl_extend('force', POSITION, {
          position_type = 'file',
          old_path = 'c.lua',
          new_path = 'c.lua',
        }),
      }, list[9].body)
      assert.same(
        { note = 'Agreed.', in_reply_to_discussion_id = 'd1' },
        list[10].body
      )
      assert.same({
        note = 'Fixed.',
        in_reply_to_discussion_id = 'd3',
        resolve_discussion = true,
      }, list[11].body)
      assert.same({ '--method', 'POST' }, vim.list_slice(list[12].args, 4, 5))
      assert.same({ '--method', 'PUT' }, vim.list_slice(list[13].args, 4, 5))
      assert.is_nil(list[13].body)
      assert.same({ body = 'Summary.' }, list[14].body)
      assert.same({ sha = 'a7a7a7' }, list[16].body)
      assert.same({
        { 'line', 'draft:900' },
        { 'range', 'draft:901' },
        { 'added', 'draft:902' },
        { 'old', 'draft:903' },
        { 'file', 'draft:904' },
        { 'outside', 'draft:905' },
        { 'reply', 'draft:906' },
        { 'both', 'draft:907' },
        { 'resolve', 'd2' },
      }, reports)
    end)

    it('refuses a draft on a file not in the diff, before any write', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      writes_succeed()
      local err, reports = submit({
        draft({ id = 'a' }),
        draft({ id = 'z', path = 'zzz.lua' }),
      }, { verdict = 'approve' })
      assert.matches('zzz.lua', err, 1, true)
      assert.same({}, reports)
      assert.same({ 'user', DRAFTS, DIFFS }, keys())
    end)

    it('refuses to place drafts when the diff cannot be read', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      writes_succeed()
      answer(DIFFS, { code = 1 })
      local err, reports = submit(
        { draft({ id = 'a' }) },
        { verdict = 'approve' }
      )
      assert.matches('502', err)
      assert.same({}, reports)
      assert.same({ 'user', DRAFTS, DIFFS }, keys())
    end)

    it('publishes my imported draft notes with the new ones', function()
      answer('user', 'user.json')
      answer(DRAFTS, {
        mine(61, 'A'),
        mine(62, 'B'),
      })
      writes_succeed()
      local err, reports = submit({
        imported(61),
        imported(62),
        draft({ id = 'new' }),
      }, { verdict = 'revoke' })
      assert.is_nil(err)
      -- Not approved: nothing to take back
      assert.same({
        'user',
        DRAFTS,
        DIFFS,
        NEW_DRAFT,
        PUBLISH,
        APPROVALS,
      }, keys())
      assert.same({
        { 'new', 'draft:900' },
        { forge_id(61), 'draft:61' },
        { forge_id(62), 'draft:62' },
      }, reports)
    end)

    it('takes back my approval', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      writes_succeed()
      answer(APPROVALS, { user_has_approved = true })
      local err = submit({ draft({ id = 'new' }) }, { verdict = 'revoke' })
      assert.is_nil(err)
      assert.same({
        'user',
        DRAFTS,
        DIFFS,
        NEW_DRAFT,
        PUBLISH,
        APPROVALS,
        MR .. '_unapprove',
      }, keys())
    end)

    it('refuses a draft note never imported, before any write', function()
      answer('user', 'user.json')
      answer(DRAFTS, { mine(61, 'A'), mine(99, 'Made on the web') })
      writes_succeed()
      local err, reports = submit(
        { imported(61), draft({ id = 'new' }) },
        { verdict = 'approve' }
      )
      assert.equals(CHANGED, err)
      assert.same({}, reports)
      assert.same({ 'user', DRAFTS }, keys())
    end)

    it('refuses an imported draft whose draft note is gone', function()
      answer('user', 'user.json')
      answer(DRAFTS, { mine(61, 'A') })
      writes_succeed()
      local err, reports = submit(
        { imported(61), imported(62), draft({ id = 'new' }) },
        { verdict = 'approve' }
      )
      assert.equals(CHANGED, err)
      assert.same({}, reports)
      assert.same({ 'user', DRAFTS }, keys())
    end)

    it('sends only the rest after a submit failed midway', function()
      answer('user', 'user.json')
      answer(DRAFTS, { mine(900, 'One.') })
      writes_succeed()
      answer(NEW_DRAFT .. '.1', { id = 901 })
      local err, reports = submit({
        draft({ id = 'a', body = 'One.', posted = 'draft:900' }),
        draft({ id = 'b', body = 'Two.' }),
      }, { verdict = 'comment' })
      assert.is_nil(err)
      assert.same({ 'user', DRAFTS, DIFFS, NEW_DRAFT, PUBLISH }, keys())
      assert.equals('Two.', calls()[4].body.note)
      assert.same({ { 'b', 'draft:901' } }, reports)
    end)

    it('publishes draft notes left by a submit cut short', function()
      answer('user', 'user.json')
      answer(DRAFTS, { mine(900, 'One.') })
      writes_succeed()
      local err, reports = submit(
        { draft({ id = 'a', body = 'One.', posted = 'draft:900' }) },
        { verdict = 'approve' }
      )
      assert.is_nil(err)
      assert.same({}, reports)
      assert.same(
        { 'user', DRAFTS, PUBLISH, APPROVALS, MR .. '_approve' },
        keys()
      )
    end)

    it('takes a draft note sent from here and imported again once', function()
      answer('user', 'user.json')
      answer(DRAFTS, { mine(900, 'One.') })
      writes_succeed()
      local err, reports = submit({
        draft({ id = 'a', body = 'One.', posted = 'draft:900' }),
        imported(900),
      }, { verdict = 'comment' })
      assert.is_nil(err)
      assert.same({ 'user', DRAFTS, PUBLISH }, keys())
      assert.same({ { forge_id(900), 'draft:900' } }, reports)
    end)

    it('stops at the first failure and never publishes then', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      writes_succeed()
      answer(NEW_DRAFT .. '.2', { code = 1 })
      local err, reports = submit({
        draft({ id = 'a' }),
        draft({ id = 'b' }),
        draft({ id = 'c' }),
      }, { verdict = 'approve' })
      assert.matches('502', err)
      assert.same({ { 'a', 'draft:900' } }, reports)
      assert.same({ 'user', DRAFTS, DIFFS, NEW_DRAFT, NEW_DRAFT }, keys())
    end)

    it('names drafts deleted before they were published', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {
        {
          id = 'dx',
          notes = {
            mine(950, 'Published.', {
              position = { new_path = 'a.lua', new_line = 1 },
            }),
          },
        },
      })
      writes_succeed()
      local err, reports, info = submit({
        draft({ id = 'out', body = 'Published.', posted = 'draft:900' }),
        draft({ id = 'lost', body = 'Deleted.', posted = 'draft:901' }),
        draft({ id = 'new' }),
      }, { verdict = 'approve' })
      assert.equals(
        '1 draft was deleted on GitLab before it was published',
        err
      )
      assert.same({ lost = { 'lost' } }, info)
      assert.same({}, reports)
      assert.same({ 'user', DRAFTS, DISCUSSIONS }, keys())
    end)

    it('finds a draft published on its file, naming its line', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {
        {
          id = 'dz',
          notes = {
            mine(970, 'L50: text', {
              position = { position_type = 'file', new_path = 'c.lua' },
            }),
          },
        },
      })
      writes_succeed()
      local err, reports, info = submit({
        draft({ id = 'out', path = 'c.lua', line = 50, posted = 'draft:905' }),
      }, { verdict = 'comment' })
      assert.is_nil(err)
      assert.same({ already = 970, mark = 970 }, info)
      assert.same({}, reports)
    end)

    it('only resolves when the review already went out', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {
        {
          id = 'dx',
          notes = {
            mine(950, 'Published.', {
              position = { new_path = 'a.lua', new_line = 1 },
            }),
          },
        },
        { id = 'dy', notes = { mine(960, 'LGTM') } },
      })
      writes_succeed()
      answer(APPROVALS, { user_has_approved = true })
      local err, reports, info = submit({
        draft({ id = 'a', body = 'Published.', posted = 'draft:900' }),
        draft({ id = 'r', reply_to = 'd2', body = '', resolve = true }),
      }, { verdict = 'approve', body = 'LGTM' })
      assert.is_nil(err)
      assert.same({ already = 960, mark = 960 }, info)
      assert.same({ { 'r', 'd2' } }, reports)
      assert.same({
        'user',
        DRAFTS,
        DISCUSSIONS,
        APPROVALS,
        MR .. '_discussions_d2_resolved_true',
      }, keys())
    end)

    it('sends the verdict alone when only it is missing', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {
        {
          id = 'dx',
          notes = {
            mine(950, 'Published.', { position = { new_path = 'a.lua' } }),
          },
        },
        { id = 'dy', notes = { mine(960, 'LGTM') } },
      })
      writes_succeed()
      local err, reports, info = submit(
        { draft({ id = 'a', body = 'Published.', posted = 'draft:900' }) },
        { verdict = 'approve', body = 'LGTM' }
      )
      assert.is_nil(err)
      assert.same({ mark = 960 }, info)
      assert.same({}, reports)
      -- The body is out already: not posted twice
      assert.same({
        'user',
        DRAFTS,
        DISCUSSIONS,
        APPROVALS,
        MR .. '_approve',
      }, keys())
    end)

    it('only resolves when a comment review would be empty', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {})
      writes_succeed()
      local err, reports, info = submit(
        { draft({ id = 'r', reply_to = 'd2', body = '', resolve = true }) },
        { verdict = 'comment' }
      )
      assert.is_nil(err)
      assert.same({ skipped = 'empty comment review' }, info)
      assert.same({ { 'r', 'd2' } }, reports)
      assert.same({
        'user',
        DRAFTS,
        DISCUSSIONS,
        MR .. '_discussions_d2_resolved_true',
      }, keys())
    end)

    it('posts a comment review body as a note', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {})
      writes_succeed()
      local err, _, info = submit({}, { verdict = 'comment', body = 'Hi.' })
      assert.is_nil(err)
      assert.same({ mark = 777 }, info)
      assert.same({ 'user', DRAFTS, DISCUSSIONS, MR .. '_notes' }, keys())
      assert.same({ body = 'Hi.' }, calls()[4].body)
    end)

    it('posts a body said in an earlier round again', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      -- Round 1's body, out before the mark of its whole submit
      answer(DISCUSSIONS, { { id = 'dy', notes = { mine(960, 'LGTM') } } })
      writes_succeed()
      local err, _, info = submit(
        {},
        { verdict = 'comment', body = 'LGTM', since = 960 }
      )
      assert.is_nil(err)
      assert.same({ 'user', DRAFTS, DISCUSSIONS, MR .. '_notes' }, keys())
      assert.same({ mark = 960 }, info)
    end)

    it('takes a body past the mark as out already', function()
      answer('user', 'user.json')
      answer(DRAFTS, {})
      answer(DISCUSSIONS, {
        { id = 'dy', notes = { mine(960, 'LGTM') } },
        { id = 'dz', notes = { mine(980, 'LGTM') } },
      })
      writes_succeed()
      local err, _, info = submit(
        {},
        { verdict = 'comment', body = 'LGTM', since = 960 }
      )
      assert.is_nil(err)
      assert.same({ already = 980, mark = 980 }, info)
      assert.same({ 'user', DRAFTS, DISCUSSIONS }, keys())
    end)

    it('submits a later round as usual after one went out', function()
      -- Round 1's comment, deleted on the web since: round 2 hands over
      -- only its own drafts
      answer('user', 'user.json')
      answer(DRAFTS, {})
      writes_succeed()
      local err, reports = submit(
        { draft({ id = 'new' }) },
        { verdict = 'comment', since = 960 }
      )
      assert.is_nil(err)
      assert.same({ { 'new', 'draft:900' } }, reports)
      assert.same({ 'user', DRAFTS, DIFFS, NEW_DRAFT, PUBLISH }, keys())
    end)

    it('fails when the drafts cannot be told published or lost', function()
      gitlab.MAX_PAGES = 1
      gitlab.PER_PAGE = 1
      answer('user', 'user.json')
      answer(MR .. '_draft_notes_per_page_1_page_1', {})
      answer(
        MR .. '_discussions_per_page_1_page_1',
        { { id = 'x', notes = {} } }
      )
      writes_succeed()
      local err, reports = submit(
        { draft({ id = 'a', posted = 'draft:900' }) },
        { verdict = 'approve' }
      )
      assert.is_string(err)
      assert.same({}, reports)
      assert.equals(3, #calls())
    end)

    it('refuses a verdict GitLab does not have, asking nothing', function()
      local err = submit({ draft({}) }, { verdict = 'request_changes' })
      assert.is_string(err)
      assert.same({}, calls())
    end)
  end)

  it('writes a suggestion in a fence longer than any it holds', function()
    assert.equals(
      '```suggestion:-0+0\na\n\nb\n```',
      gitlab.suggestion({ 'a', '', 'b' })
    )
    assert.equals(
      '`````suggestion:-0+0\n````\n`````',
      gitlab.suggestion({ '````' })
    )
  end)

  it('offers the verdicts GitLab has', function()
    assert.same(
      { 'approve', 'revoke', 'comment' },
      vim.tbl_map(function(v) return v.id end, gitlab.verdicts)
    )
  end)
end)

describe('tools.review.forge', function()
  it('picks the GitLab adapter for a GitLab remote', function()
    h.unload('tools.review.forge', 'tools.review.forge.gitlab')
    local forge = require('tools.review.forge')
    assert.equals(
      require('tools.review.forge.gitlab'),
      (forge.for_remote({ kind = 'gitlab', host = 'h', slug = 'g/p' }))
    )
  end)
end)
