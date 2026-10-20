local h = require('helpers')

local FIXTURES = h.root .. '/tests/fixtures/review/azure/'

describe('tools.review.forge.azure', function()
  local azure, dir, cleanup, path
  local remote = {
    name = 'origin',
    kind = 'azure',
    host = 'dev.azure.com',
    slug = 'contoso/My Project/web',
    org = 'contoso',
    project = 'My Project',
    repo = 'web',
  }
  local ME = '11111111-aaaa-bbbb-cccc-000000000001'

  --- The fake `az`: it records each call's arguments and the body of its
  --- `--in-file`, and answers from `answers/<key>.<n>.json` for the n-th call
  --- of that key, else from `answers/<key>.json`. The key is the method and
  --- the resource, then the pull request, thread and iteration of the route
  --- and the `$skip` of the query, `_branch` for a lookup by branch. A
  --- `<key>.code` file makes it fail.
  local FAKE = [[
#!/bin/sh
d="%s"
n=$(( $(cat "$d/count" 2>/dev/null || echo 0) + 1 ))
echo "$n" > "$d/count"
printf '%%s\n' "$@" > "$d/calls/$n.args"
method=GET; resource=; extra=; file=; mode=
for a; do
  case "$mode" in
    method) method=$a; mode=; continue ;;
    resource) resource=$a; mode=; continue ;;
    file) file=$a; mode=; continue ;;
  esac
  case "$a" in
    --http-method) mode=method ;;
    --resource) mode=resource ;;
    --in-file) mode=file ;;
    iterationId=*|pullRequestId=*|threadId=*|'$skip='*) extra="${extra}_${a#*=}" ;;
    searchCriteria.sourceRefName=*) extra="${extra}_branch" ;;
  esac
done
if [ -n "$file" ]; then cat "$file" > "$d/calls/$n.body"; else : > "$d/calls/$n.body"; fi
key="${method}_${resource}${extra}"
echo "$key" > "$d/calls/$n.key"
k=$(( $(cat "$d/count.$key" 2>/dev/null || echo 0) + 1 ))
echo "$k" > "$d/count.$key"
if [ -f "$d/answers/$key.$k.code" ] || [ -f "$d/answers/$key.code" ]; then
  echo "TF400898: failed for $key" >&2
  exit 1
fi
if [ -f "$d/answers/$key.$k.json" ]; then cat "$d/answers/$key.$k.json"; exit 0; fi
if [ -f "$d/answers/$key.json" ]; then cat "$d/answers/$key.json"; exit 0; fi
echo "no answer for $key" >&2
exit 1
]]

  before_each(function()
    h.unload('tools.review.forge.azure', 'util.forge')
    azure = require('tools.review.forge.azure')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/calls', 'p')
    vim.fn.mkdir(dir .. '/answers', 'p')
    h.write(dir .. '/bin/az', vim.split(FAKE:format(dir), '\n'))
    vim.fn.setfperm(dir .. '/bin/az', 'rwxr-xr-x')
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

  --- Every call the fake answered, in order: its key, arguments and body
  ---@return { key: string, args: string[], body: any }[]
  local function calls()
    local list = {}
    local count = 0
    if vim.uv.fs_stat(dir .. '/count') then
      count = tonumber(vim.fn.readfile(dir .. '/count')[1]) or 0
    end
    for n = 1, count do
      local base = ('%s/calls/%d'):format(dir, n)
      local body = table.concat(vim.fn.readfile(base .. '.body'), '\n')
      list[n] = {
        key = vim.fn.readfile(base .. '.key')[1],
        args = vim.fn.readfile(base .. '.args'),
        body = body ~= '' and vim.json.decode(body) or nil,
      }
    end
    return list
  end

  --- The keys of every call, in order
  ---@return string[]
  local function keys()
    return vim.tbl_map(function(call) return call.key end, calls())
  end

  --- The value of `--<flag>` among `args`, and the words up to the next flag
  ---@param args string[]
  ---@param flag string
  ---@return string[]
  local function flag_words(args, flag)
    local words, on = {}, false
    for _, arg in ipairs(args) do
      if arg:match('^%-%-') then
        on = arg == flag
      elseif on then
        words[#words + 1] = arg
      end
    end
    return words
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

  local WHO = 'GET_connectionData'
  local LIST = 'GET_pullRequests_0'
  local GET = 'GET_pullRequests_7'
  local THREADS = 'GET_pullRequestThreads_7'
  local NEW_THREAD = 'POST_pullRequestThreads_7'
  local REVIEWERS = 'GET_pullRequestReviewers_7'
  local VOTE = 'PUT_pullRequestReviewers_7'
  local ITERATIONS = 'GET_pullRequestIterations_7'
  local CHANGES = 'GET_pullRequestIterationChanges_3_7_0'

  --- A pull request row of the API
  ---@param fields? table
  ---@return table
  local function row(fields)
    return vim.tbl_extend('force', {
      pullRequestId = 7,
      status = 'active',
      title = 't',
      sourceRefName = 'refs/heads/feat/x',
      targetRefName = 'refs/heads/main',
      mergeStatus = 'succeeded',
      lastMergeSourceCommit = { commitId = 'a7' },
      lastMergeTargetCommit = { commitId = 'b7' },
      lastMergeCommit = { commitId = 'm7' },
    }, fields or {})
  end

  describe('list', function()
    it('reads active pull requests and whether my review is asked', function()
      answer(WHO, 'connection.json')
      answer(LIST, 'pulls.json')
      local pulls, err, capped = wait(function(cb) azure.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_false(capped)
      -- One whose merge is not worked out yet cannot be reviewed
      assert.equals(2, #pulls)
      assert.same({
        id = '7',
        title = 'Add a parser',
        author = 'Alice',
        body = 'Parses things.',
        url = 'https://dev.azure.com/contoso/My%20Project/_git/web/pullrequest/7',
        base_ref = 'main',
        head_ref = 'feat/parser',
        base_sha = 'b7b7b7',
        head_sha = 'a7a7a7',
        fetch = {
          '+refs/pull/7/merge:refs/dyneo/review/azure-7/merge',
        },
        fork = false,
        requested = true,
      }, pulls[1])
      assert.equals('8', pulls[2].id)
      assert.equals('ghost', pulls[2].author)
      assert.is_true(pulls[2].fork)
      assert.is_false(pulls[2].requested)
      local args = calls()[2].args
      assert.same({ 'git' }, flag_words(args, '--area'))
      assert.same({ 'pullRequests' }, flag_words(args, '--resource'))
      assert.same(
        { 'project=My Project', 'repositoryId=web' },
        flag_words(args, '--route-parameters')
      )
      assert.same({
        '$skip=0',
        '$top=100',
        'searchCriteria.status=active',
      }, flag_words(args, '--query-parameters'))
      local who = calls()[1].args
      assert.same({ 'Location' }, flag_words(who, '--area'))
      assert.same({ 'connectionData' }, flag_words(who, '--resource'))
      assert.same({ '7.1-preview' }, flag_words(who, '--api-version'))
      assert.same({ '7.1' }, flag_words(args, '--api-version'))
    end)

    it('asks who I am once per organization', function()
      answer(WHO, 'connection.json')
      answer(LIST, { count = 0, value = {} })
      wait(function(cb) azure.list(remote, cb) end)
      wait(function(cb) azure.list(remote, cb) end)
      assert.same({ WHO, LIST, LIST }, keys())
    end)

    it('reads every page and says when it stopped at the last', function()
      azure.PER_PAGE = 1
      azure.MAX_PAGES = 2
      answer(WHO, 'connection.json')
      answer('GET_pullRequests_0', { value = { row({ pullRequestId = 1 }) } })
      answer('GET_pullRequests_1', { value = { row({ pullRequestId = 2 }) } })
      local pulls, err, capped = wait(function(cb) azure.list(remote, cb) end)
      assert.is_nil(err)
      assert.is_true(capped)
      assert.equals(2, #pulls)
    end)

    it('fails the whole listing when a page fails', function()
      azure.PER_PAGE = 1
      answer(WHO, 'connection.json')
      answer('GET_pullRequests_0', { value = { row() } })
      answer('GET_pullRequests_1', { code = 1 })
      local pulls, err = wait(function(cb) azure.list(remote, cb) end)
      assert.is_nil(pulls)
      assert.matches('TF400898', err)
    end)

    it('refuses a remote that is not Azure DevOps, asking nothing', function()
      local pulls, err = wait(
        function(cb)
          azure.list({ kind = 'azure', host = 'h', slug = 'x', name = 'o' }, cb)
        end
      )
      assert.is_nil(pulls)
      assert.is_string(err)
      assert.same({}, calls())
    end)
  end)

  describe('get', function()
    it('fetches the merge ref, whose second parent is the head', function()
      answer(GET, 'pull.json')
      local pull, err = wait(function(cb) azure.get(remote, '7', cb) end)
      assert.is_nil(err)
      assert.equals('a7a7a7', pull.head_sha)
      assert.equals('b7b7b7', pull.base_sha)
      assert.same(
        { '+refs/pull/7/merge:refs/dyneo/review/azure-7/merge' },
        pull.fetch
      )
      assert.is_nil(pull.read_only)
      assert.same({
        'pullRequestId=7',
        'project=My Project',
        'repositoryId=web',
      }, {
        flag_words(calls()[1].args, '--route-parameters')[2],
        flag_words(calls()[1].args, '--route-parameters')[1],
        flag_words(calls()[1].args, '--route-parameters')[3],
      })
    end)

    it('fetches the source branch when there is no merge ref', function()
      answer(GET, row({ mergeStatus = 'conflicts', lastMergeCommit = vim.NIL }))
      local pull, err = wait(function(cb) azure.get(remote, '7', cb) end)
      assert.is_nil(err)
      assert.equals('a7', pull.head_sha)
      assert.equals('b7', pull.base_sha)
      assert.same({
        '+refs/heads/feat/x:refs/dyneo/review/azure-7/head',
        '+refs/heads/main:refs/dyneo/review/azure-7/base',
      }, pull.fetch)
      assert.is_nil(pull.read_only)
      assert.is_nil(pull.unfetchable)
    end)

    it('opens a fork without a merge ref read-only', function()
      answer(
        GET,
        row({
          mergeStatus = 'conflicts',
          lastMergeCommit = vim.NIL,
          forkSource = { name = 'refs/heads/feat/x' },
        })
      )
      local pull = wait(function(cb) azure.get(remote, '7', cb) end)
      assert.is_true(pull.fork)
      assert.equals(
        'the source branch lives in a fork that cannot be fetched',
        pull.read_only
      )
      assert.equals(pull.read_only, pull.unfetchable)
      assert.same(
        { '+refs/heads/main:refs/dyneo/review/azure-7/base' },
        pull.fetch
      )
    end)

    it('reviews a fork through its merge ref', function()
      answer(GET, row({ forkSource = { name = 'refs/heads/feat/x' } }))
      local pull = wait(function(cb) azure.get(remote, '7', cb) end)
      assert.is_true(pull.fork)
      assert.is_nil(pull.read_only)
      assert.same(
        { '+refs/pull/7/merge:refs/dyneo/review/azure-7/merge' },
        pull.fetch
      )
    end)

    it('never puts a strange branch name in a refspec', function()
      answer(
        GET,
        row({
          mergeStatus = 'conflicts',
          lastMergeCommit = vim.NIL,
          sourceRefName = 'refs/heads/-x/../y',
        })
      )
      local pull = wait(function(cb) azure.get(remote, '7', cb) end)
      assert.is_string(pull.read_only)
      for _, spec in ipairs(pull.fetch) do
        assert.is_nil(spec:find('..', 1, true))
      end
    end)

    it('opens merged and abandoned pull requests read-only', function()
      answer(GET .. '.1', row({ status = 'completed' }))
      answer(GET .. '.2', row({ status = 'abandoned' }))
      local merged = wait(function(cb) azure.get(remote, '7', cb) end)
      local abandoned = wait(function(cb) azure.get(remote, '7', cb) end)
      assert.matches('merged', merged.read_only)
      assert.matches('abandoned', abandoned.read_only)
    end)

    it('refuses an id that is not a number, asking nothing', function()
      local pull, err = wait(function(cb) azure.get(remote, '1/../x', cb) end)
      assert.is_nil(pull)
      assert.is_string(err)
      assert.same({}, calls())
    end)
  end)

  describe('for_branch', function()
    it('finds the pull request of a branch of this repository', function()
      answer('GET_pullRequests_branch', {
        value = {
          row({ pullRequestId = 4, forkSource = { name = 'x' } }),
          row({ pullRequestId = 7 }),
        },
      })
      answer(GET, 'pull.json')
      local pull, err = wait(
        function(cb) azure.for_branch(remote, 'feat/parser', cb) end
      )
      assert.is_nil(err)
      assert.equals('7', pull.id)
      assert.same({ 'GET_pullRequests_branch', GET }, keys())
      assert.is_true(
        vim.tbl_contains(
          flag_words(calls()[1].args, '--query-parameters'),
          'searchCriteria.sourceRefName=refs/heads/feat/parser'
        )
      )
    end)

    it('hands nil without an error when the branch has none', function()
      answer('GET_pullRequests_branch', { value = {} })
      local pull, err = wait(
        function(cb) azure.for_branch(remote, 'feat/x', cb) end
      )
      assert.is_nil(pull)
      assert.is_nil(err)
    end)
  end)

  describe('threads', function()
    local pull = { id = '7' }

    it('reads every thread on a file', function()
      answer(THREADS, 'threads.json')
      local threads, err, capped = wait(
        function(cb) azure.threads(remote, pull, cb) end
      )
      assert.is_nil(err)
      assert.is_false(capped)
      assert.same({
        {
          id = '5',
          path = 'a.lua',
          side = 'new',
          line = 10,
          start_line = 8,
          resolved = false,
          comments = {
            { author = 'Alice', body = 'Why?', time = '2026-10-01T10:00:00Z' },
            {
              author = 'ghost',
              body = 'Because.',
              time = '2026-10-01T11:00:00Z',
            },
          },
        },
        {
          id = '6',
          path = 'b.lua',
          side = 'old',
          line = 4,
          resolved = true,
          comments = {
            {
              author = 'Bob',
              body = 'Gone now.',
              time = '2026-10-02T10:00:00Z',
            },
          },
        },
        {
          id = '7',
          path = 'c.lua',
          side = 'new',
          resolved = true,
          comments = {
            {
              author = 'Carol',
              body = 'Whole file.',
              time = '2026-10-03T10:00:00Z',
            },
          },
        },
      }, threads)
    end)

    it(
      'fails when Azure DevOps hands over fewer threads than it has',
      function()
        answer(THREADS, { count = 3, value = {} })
        local threads, err = wait(
          function(cb) azure.threads(remote, pull, cb) end
        )
        assert.is_nil(threads)
        assert.is_string(err)
      end
    )
  end)

  it('has no pending drafts to import', function()
    local drafts, err = wait(
      function(cb) azure.pending(remote, { id = '7' }, cb) end
    )
    assert.same({}, drafts)
    assert.is_nil(err)
    assert.same({}, calls())
    assert.is_nil(azure.import_id('5'))
  end)

  describe('submit', function()
    local pull = { id = '7', head_sha = 'a7a7a7', base_sha = 'b7b7b7' }

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

    --- Submit `drafts` with `review` and hand back the error, every
    --- `progress` report as `{ draft id, forge id }`, and the info
    local function submit(drafts, review)
      local reports = {}
      local err, info = wait(function(cb)
        azure.submit(
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

    --- A thread of mine, `id`, holding `body`, on `context` or the pull
    --- request itself
    local function mine(id, body, context, extra)
      return vim.tbl_extend('force', {
        id = id,
        status = 'active',
        threadContext = context or vim.NIL,
        comments = {
          {
            id = 1,
            author = { id = ME },
            content = body,
            commentType = 'text',
          },
        },
      }, extra or {})
    end

    --- My vote as the reviewer list says it, none when nil
    ---@param vote? integer
    local function my_vote(vote)
      answer(REVIEWERS, {
        count = vote and 2 or 1,
        value = {
          { id = 'other', vote = -10 },
          vote and { id = ME:upper(), vote = vote } or nil,
        },
      })
    end

    --- Answer every read and write of a submit that succeeds; threads are
    --- numbered from 100 on, replies from 2 on
    local function writes_succeed()
      answer(WHO, 'connection.json')
      answer(THREADS, { count = 0, value = {} })
      my_vote(nil)
      answer(ITERATIONS, 'iterations.json')
      answer(CHANGES, 'changes.json')
      for n = 1, 9 do
        answer(NEW_THREAD .. '.' .. n, { id = 99 + n })
      end
      answer('POST_pullRequestThreadComments_7_5', { id = 2 })
      answer('POST_pullRequestThreadComments_7_6', { id = 3 })
      answer('PATCH_pullRequestThreads_7_6', { id = 6, status = 'fixed' })
      answer('PATCH_pullRequestThreads_7_8', { id = 8, status = 'fixed' })
      answer(VOTE, { id = ME, vote = 10 })
    end

    --- The thread context of a POST, as Azure DevOps takes it
    local function at(path, side, first, last)
      local context = { filePath = '/' .. path }
      if side then
        local s = side == 'new' and 'right' or 'left'
        context[s .. 'FileStart'] = { line = first, offset = 1 }
        context[s .. 'FileEnd'] = { line = last, offset = 1 }
      end
      return context
    end

    --- The pull request context of a POST on the file tracked as `id`
    local function tracked(id)
      return {
        changeTrackingId = id,
        iterationContext = {
          firstComparingIteration = 1,
          secondComparingIteration = 3,
        },
      }
    end

    --- A new thread's comment holding `text`
    local function first(text)
      return { { parentCommentId = 0, content = text, commentType = 1 } }
    end

    it(
      'posts threads, replies, resolutions, the body, then the vote',
      function()
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
          draft({ id = 'old', path = 'b.lua', side = 'old', line = 2 }),
          draft({
            id = 'file',
            path = 'c.lua',
            line = 40,
            body = 'Outside.',
            file_level = true,
          }),
          draft({ id = 'reply', reply_to = '5', body = 'Agreed.' }),
          draft({
            id = 'both',
            reply_to = '6',
            body = 'Fixed.',
            resolve = true,
          }),
          draft({ id = 'resolve', reply_to = '8', body = '', resolve = true }),
        }, { verdict = 'approve', body = 'Summary.' })
        assert.is_nil(err)
        assert.is_nil(info)
        assert.same({
          WHO,
          THREADS,
          REVIEWERS,
          ITERATIONS,
          CHANGES,
          NEW_THREAD,
          NEW_THREAD,
          NEW_THREAD,
          NEW_THREAD,
          'POST_pullRequestThreadComments_7_5',
          'POST_pullRequestThreadComments_7_6',
          'PATCH_pullRequestThreads_7_6',
          'PATCH_pullRequestThreads_7_8',
          NEW_THREAD,
          VOTE,
        }, keys())
        local list = calls()
        assert.same({
          comments = first('One line.'),
          status = 1,
          threadContext = at('a.lua', 'new', 3, 3),
          pullRequestThreadContext = tracked(11),
        }, list[6].body)
        assert.same({
          comments = first('A range.\n\n````\nx = 1\ny = ```z```\n````'),
          status = 1,
          threadContext = at('a.lua', 'new', 5, 8),
          pullRequestThreadContext = tracked(11),
        }, list[7].body)
        -- The old side of a renamed file goes by its new path
        assert.same({
          comments = first('text'),
          status = 1,
          threadContext = at('b.lua', 'old', 2, 2),
          pullRequestThreadContext = tracked(12),
        }, list[8].body)
        assert.same({
          comments = first('L40: Outside.'),
          status = 1,
          threadContext = at('c.lua'),
          pullRequestThreadContext = tracked(13),
        }, list[9].body)
        assert.same(
          { content = 'Agreed.', parentCommentId = 1, commentType = 1 },
          list[10].body
        )
        assert.same(
          { content = 'Fixed.', parentCommentId = 1, commentType = 1 },
          list[11].body
        )
        assert.same({ 'PATCH' }, flag_words(list[12].args, '--http-method'))
        assert.same({ status = 'fixed' }, list[12].body)
        assert.same({ status = 'fixed' }, list[13].body)
        -- A summary that asks nothing of the author never blocks a merge
        assert.same({ comments = first('Summary.'), status = 4 }, list[14].body)
        assert.same({ 'PUT' }, flag_words(list[15].args, '--http-method'))
        assert.is_true(
          vim.tbl_contains(
            flag_words(list[15].args, '--route-parameters'),
            'reviewerId=' .. ME
          )
        )
        assert.same({ id = ME, vote = 10 }, list[15].body)
        assert.same(
          { 'iterationId=3', 'project=My Project', 'pullRequestId=7' },
          vim.list_slice(flag_words(list[5].args, '--route-parameters'), 1, 3)
        )
        assert.same({
          { 'line', '100' },
          { 'range', '101' },
          { 'old', '102' },
          { 'file', '103' },
          { 'reply', '5/2' },
          { 'both', '6/3' },
          { 'resolve', '8' },
        }, reports)
      end
    )

    for verdict, vote in pairs({
      approve = 10,
      approve_with_suggestions = 5,
      no_vote = 0,
      wait_for_author = -5,
      reject = -10,
    }) do
      it(('votes %d for %s, last'):format(vote, verdict), function()
        writes_succeed()
        -- A vote of mine to change, whatever is asked
        my_vote(vote == 10 and -10 or 10)
        local err = submit({ draft({ id = 'a' }) }, { verdict = verdict })
        assert.is_nil(err)
        local list = calls()
        assert.equals(VOTE, list[#list].key)
        assert.same({ id = ME, vote = vote }, list[#list].body)
      end)
    end

    it('leaves a vote alone when it is already the one asked', function()
      writes_succeed()
      my_vote(5)
      local err = submit(
        { draft({ id = 'a' }) },
        { verdict = 'approve_with_suggestions' }
      )
      assert.is_nil(err)
      assert.same(
        { WHO, THREADS, REVIEWERS, ITERATIONS, CHANGES, NEW_THREAD },
        keys()
      )
    end)

    it(
      'refuses a draft on a file not in the changes, before any write',
      function()
        writes_succeed()
        local err, reports = submit({
          draft({ id = 'a' }),
          draft({ id = 'z', path = 'zzz.lua' }),
        }, { verdict = 'approve' })
        assert.matches('zzz.lua', err, 1, true)
        assert.same({}, reports)
        assert.same({ WHO, THREADS, REVIEWERS, ITERATIONS, CHANGES }, keys())
      end
    )

    it('fails before any write when the changes are cut short', function()
      azure.MAX_PAGES = 1
      writes_succeed()
      answer(CHANGES, {
        changeEntries = {
          { changeTrackingId = 11, item = { path = '/a.lua' } },
        },
        nextSkip = 2000,
        nextTop = 2000,
      })
      local err, reports = submit(
        { draft({ id = 'a' }) },
        { verdict = 'approve' }
      )
      assert.is_string(err)
      assert.same({}, reports)
      assert.same({ WHO, THREADS, REVIEWERS, ITERATIONS, CHANGES }, keys())
    end)

    it('reads the changes a page at a time', function()
      writes_succeed()
      answer(CHANGES, {
        changeEntries = {
          { changeTrackingId = 11, item = { path = '/x.lua' } },
        },
        nextSkip = 1,
        nextTop = 2000,
      })
      answer('GET_pullRequestIterationChanges_3_7_1', 'changes.json')
      local err = submit({ draft({ id = 'a' }) }, { verdict = 'approve' })
      assert.is_nil(err)
      assert.equals('GET_pullRequestIterationChanges_3_7_1', calls()[6].key)
    end)

    it('fails before any write when the threads are cut short', function()
      writes_succeed()
      answer(THREADS, { count = 5, value = { mine(100, 'One.') } })
      local err, reports = submit({
        draft({ id = 'a', body = 'One.', posted = '100' }),
        draft({ id = 'b' }),
      }, { verdict = 'approve' })
      assert.is_string(err)
      assert.same({}, reports)
      assert.same({ WHO, THREADS }, keys())
    end)

    it('refuses drafts whose thread is gone, before any write', function()
      writes_succeed()
      answer(THREADS, {
        value = {
          mine(100, 'Out.', at('a.lua', 'new', 1, 1)),
          mine(101, 'Deleted.', vim.NIL, { isDeleted = true }),
          mine(5, 'Why?', vim.NIL, {
            comments = {
              { id = 1, author = { id = 'x' }, content = 'Why?' },
              {
                id = 2,
                author = { id = ME },
                content = 'No.',
                isDeleted = true,
              },
            },
          }),
        },
      })
      local err, reports, info = submit({
        draft({ id = 'out', body = 'Out.', posted = '100' }),
        draft({ id = 'deleted', posted = '101' }),
        draft({ id = 'missing', posted = '102' }),
        draft({ id = 'reply', reply_to = '5', posted = '5/2' }),
        draft({ id = 'new' }),
      }, { verdict = 'approve' })
      assert.equals('3 drafts were deleted on Azure DevOps', err)
      assert.same({ lost = { 'deleted', 'missing', 'reply' } }, info)
      assert.same({}, reports)
      assert.same({ WHO, THREADS }, keys())
    end)

    it('sends only the rest after a submit failed midway', function()
      writes_succeed()
      answer(
        THREADS,
        { value = { mine(100, 'One.', at('a.lua', 'new', 1, 1)) } }
      )
      answer(NEW_THREAD .. '.1', { id = 101 })
      local err, reports = submit({
        draft({ id = 'a', body = 'One.', posted = '100' }),
        draft({ id = 'b', body = 'Two.' }),
      }, { verdict = 'approve' })
      assert.is_nil(err)
      assert.same({
        WHO,
        THREADS,
        REVIEWERS,
        ITERATIONS,
        CHANGES,
        NEW_THREAD,
        VOTE,
      }, keys())
      assert.same(first('Two.'), calls()[6].body.comments)
      assert.same({ { 'b', '101' } }, reports)
    end)

    it('resolves a thread a sent reply was to resolve, still open', function()
      writes_succeed()
      answer(THREADS, {
        value = {
          mine(6, 'Why?', at('b.lua', 'old', 4, 4), {
            comments = {
              { id = 1, author = { id = 'x' }, content = 'Why?' },
              { id = 3, author = { id = ME }, content = 'Fixed.' },
            },
          }),
        },
      })
      my_vote(10)
      local err, reports, info = submit({
        draft({
          id = 'both',
          reply_to = '6',
          body = 'Fixed.',
          resolve = true,
          posted = '6/3',
        }),
      }, { verdict = 'approve' })
      assert.is_nil(err)
      assert.same({ already = 10 }, info)
      assert.same({}, reports)
      assert.same(
        { WHO, THREADS, REVIEWERS, 'PATCH_pullRequestThreads_7_6' },
        keys()
      )
    end)

    it('stops at the first failure, before the vote', function()
      writes_succeed()
      answer(NEW_THREAD .. '.2', { code = 1 })
      local err, reports = submit({
        draft({ id = 'a' }),
        draft({ id = 'b' }),
        draft({ id = 'c' }),
      }, { verdict = 'approve' })
      assert.matches('TF400898', err)
      assert.same({ { 'a', '100' } }, reports)
      assert.same({
        WHO,
        THREADS,
        REVIEWERS,
        ITERATIONS,
        CHANGES,
        NEW_THREAD,
        NEW_THREAD,
      }, keys())
    end)

    it('only resolves when the review already went out', function()
      writes_succeed()
      answer(THREADS, {
        value = {
          mine(100, 'One.', at('a.lua', 'new', 1, 1)),
          mine(101, 'LGTM'),
        },
      })
      my_vote(10)
      local err, reports, info = submit({
        draft({ id = 'a', body = 'One.', posted = '100' }),
        draft({ id = 'r', reply_to = '6', body = '', resolve = true }),
      }, { verdict = 'approve', body = 'LGTM' })
      assert.is_nil(err)
      assert.same({ already = 10 }, info)
      assert.same({ { 'r', '6' } }, reports)
      assert.same(
        { WHO, THREADS, REVIEWERS, 'PATCH_pullRequestThreads_7_6' },
        keys()
      )
    end)

    it('sends the vote alone when only it is missing', function()
      writes_succeed()
      answer(THREADS, {
        value = {
          mine(100, 'One.', at('a.lua', 'new', 1, 1)),
          mine(101, 'LGTM'),
        },
      })
      my_vote(0)
      local err, reports, info = submit(
        { draft({ id = 'a', body = 'One.', posted = '100' }) },
        { verdict = 'reject', body = 'LGTM' }
      )
      assert.is_nil(err)
      assert.is_nil(info)
      assert.same({}, reports)
      -- The body is out already: not posted twice
      assert.same({ WHO, THREADS, REVIEWERS, VOTE }, keys())
      assert.same({ id = ME, vote = -10 }, calls()[4].body)
    end)

    it('only resolves when a no-vote review would be empty', function()
      writes_succeed()
      local err, reports, info = submit(
        { draft({ id = 'r', reply_to = '6', body = '', resolve = true }) },
        { verdict = 'no_vote' }
      )
      assert.is_nil(err)
      assert.same({ skipped = 'empty comment review' }, info)
      assert.same({ { 'r', '6' } }, reports)
      assert.same(
        { WHO, THREADS, REVIEWERS, 'PATCH_pullRequestThreads_7_6' },
        keys()
      )
    end)

    it('posts a no-vote body as a thread on the pull request', function()
      writes_succeed()
      local err, _, info = submit({}, { verdict = 'no_vote', body = 'Hi.' })
      assert.is_nil(err)
      assert.is_nil(info)
      assert.same({ WHO, THREADS, REVIEWERS, NEW_THREAD }, keys())
      assert.same({ comments = first('Hi.'), status = 4 }, calls()[4].body)
    end)

    for _, verdict in ipairs({ 'wait_for_author', 'reject' }) do
      it(
        ('leaves the body of %s open for the author'):format(verdict),
        function()
          writes_succeed()
          local err = submit({}, { verdict = verdict, body = 'Fix it.' })
          assert.is_nil(err)
          assert.same({ WHO, THREADS, REVIEWERS, NEW_THREAD, VOTE }, keys())
          assert.same(
            { comments = first('Fix it.'), status = 1 },
            calls()[4].body
          )
        end
      )
    end

    it(
      'refuses a verdict Azure DevOps does not have, asking nothing',
      function()
        local err = submit({ draft({}) }, { verdict = 'request_changes' })
        assert.is_string(err)
        assert.same({}, calls())
      end
    )
  end)

  it(
    'has no suggestion syntax',
    function() assert.is_nil(azure.suggestion({ 'a' })) end
  )

  it('offers the votes Azure DevOps has', function()
    assert.same({
      'approve',
      'approve_with_suggestions',
      'wait_for_author',
      'reject',
      'no_vote',
    }, vim.tbl_map(function(v) return v.id end, azure.verdicts))
  end)
end)

describe('tools.review.forge', function()
  it('picks the Azure DevOps adapter for an Azure DevOps remote', function()
    h.unload('tools.review.forge', 'tools.review.forge.azure')
    local forge = require('tools.review.forge')
    assert.equals(require('tools.review.forge.azure'), (forge.for_remote({
      kind = 'azure',
      host = 'dev.azure.com',
      slug = 'o/p/r',
    })))
  end)
end)
