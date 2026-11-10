local h = require('helpers')

describe('tools.bisect', function()
  local bisect, dir, repo, cleanup, notes, restores, trusted, env
  local shas = {}

  local function git(args, cwd)
    local result = require('util.system').sync(
      vim.list_extend({
        'git',
        '-c',
        'user.name=Tester',
        '-c',
        'user.email=t@example.com',
        '-c',
        'commit.gpgsign=false',
        '-c',
        'tag.gpgsign=false',
      }, args),
      { cwd = cwd or repo, timeout = 10000 }
    )
    assert.equals(0, result.code, result.stderr)
    return vim.trim(result.stdout)
  end

  --- What a run must leave as it was: the branch, HEAD and working tree
  local function state()
    return {
      branch = git({ 'symbolic-ref', 'HEAD' }),
      head = git({ 'rev-parse', 'HEAD' }),
      status = git({ 'status', '--porcelain', '--untracked-files=all' }),
      worktrees = #vim.split(git({ 'worktree', 'list' }), '\n'),
      bisect = vim.uv.fs_stat(repo .. '/.git/BISECT_LOG') ~= nil,
    }
  end

  local function noted(pattern)
    for _, note in ipairs(notes) do
      if note.msg:match(pattern) then return note end
    end
  end

  --- Wait until the run is over and a note matches `pattern`
  local function settled(pattern)
    assert.is_true(
      vim.wait(
        30000,
        function() return bisect.current == nil and noted(pattern) ~= nil end,
        50
      ),
      vim.inspect(notes)
    )
  end

  local function leftovers()
    return vim.fn.glob(dir .. '/cache/dyneo/bisect/*', true, true)
  end

  before_each(function()
    h.unload('tools.bisect')
    bisect = require('tools.bisect')
    dir, cleanup = h.tmpdir()
    repo = dir .. '/repo'
    vim.fn.mkdir(repo, 'p')
    -- Only this spec's git configuration, whatever the machine has
    env = { vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM }
    vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
    vim.env.GIT_CONFIG_NOSYSTEM = '1'
    git({ 'init', '-q', '-b', 'main' })
    -- `f` turns from `ok` to `bad` at commit 5 of 8
    for i = 1, 8 do
      h.write(repo .. '/f', { i < 5 and 'ok' or 'bad' })
      h.write(repo .. '/n', { tostring(i) })
      git({ 'add', '.' })
      git({ 'commit', '-q', '-m', 'commit ' .. i })
      shas[i] = git({ 'rev-parse', 'HEAD' })
    end
    -- Changes of the user the run must not see nor touch
    h.write(repo .. '/f', { 'ok' })
    h.write(repo .. '/untracked', { 'mine' })
    notes, trusted = {}, true
    local stdpath = vim.fn.stdpath
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(package.loaded, 'util.trust', {
        ask = function() return trusted end,
      }),
      h.stub(
        vim.fn,
        'stdpath',
        function(what)
          return what == 'cache' and dir .. '/cache' or stdpath(what)
        end
      ),
    }
    vim.cmd.cd(repo)
  end)

  after_each(function()
    if bisect.current then
      bisect.stop()
      vim.wait(10000, function() return bisect.current == nil end)
    end
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.env.GIT_CONFIG_GLOBAL, vim.env.GIT_CONFIG_NOSYSTEM = env[1], env[2]
    vim.cmd('silent! stopinsert')
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! only!')
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd('-')
    cleanup()
  end)

  it('finds the commit that broke the check, and leaves no trace', function()
    local before = state()
    bisect.command(shas[1] .. ' -- grep -qx ok f')
    settled('First bad commit .* commit 5\nTester, %d+%-%d+%-%d+')
    assert.truthy(noted(shas[5]:sub(1, 12) .. ' is the first bad commit'))
    assert.equals('dybisect://' .. shas[5], vim.api.nvim_buf_get_name(0))
    assert.same(before, state())
    assert.same({}, leftovers())
    -- The check ran on committed code: the edited `f` says `ok`
    assert.same({ 'ok' }, vim.fn.readfile(repo .. '/f'))
  end)

  it('asks for the refs and the check, the last tag as good', function()
    git({ 'tag', 'v1', shas[2] })
    local prompts = {}
    restores[#restores + 1] = h.stub(vim.ui, 'input', function(opts, cb)
      table.insert(prompts, opts.default)
      cb(#prompts == 1 and opts.default or 'grep -qx ok f')
    end)
    bisect.command('')
    vim.wait(10000, function() return #prompts == 2 end)
    assert.equals('v1', prompts[1])
    settled('is the first bad commit')
    assert.truthy(noted(shas[5]:sub(1, 12)))
    assert.equals('grep -qx ok f', bisect.last_cmd[repo])
  end)

  it('says when the check passes at the bad commit', function()
    bisect.command(shas[1] .. ' -- true')
    settled('passes at the bad commit')
    assert.same({}, leftovers())
  end)

  it('says when the check fails at the good commit already', function()
    bisect.command(shas[1] .. ' -- false')
    settled('fails at the good commit')
    assert.is_nil(noted('first bad commit'))
    assert.same({}, leftovers())
  end)

  it('lists the candidates when only skipped commits are left', function()
    bisect.command(
      shas[1]
        .. ' -- grep -qx ok f || { [ "$(cat n)" -lt 8 ] && exit 125; exit 1; }'
    )
    settled('Only skipped commits are left')
    assert.truthy(noted(shas[5]:sub(1, 12)))
    assert.is_nil(noted('is the first bad commit'))
    assert.same({}, leftovers())
  end)

  it('stops a run and removes its worktree', function()
    local before = state()
    bisect.command(shas[1] .. ' -- sleep 30; grep -qx ok f')
    assert.is_true(
      vim.wait(
        10000,
        function() return bisect.current ~= nil and bisect.current.job ~= nil end
      )
    )
    assert.equals(1, #leftovers())
    bisect.command('stop')
    settled('stopped')
    assert.same(before, state())
    assert.same({}, leftovers())
  end)

  it('runs one bisect at a time', function()
    bisect.command(shas[1] .. ' -- sleep 30')
    bisect.command(shas[1] .. ' -- true')
    assert.truthy(noted('A bisect is going on'))
  end)

  it('refuses a ref that is no commit, or not an ancestor', function()
    local before = state()
    bisect.command('nope -- true')
    settled('"nope" is not a commit')
    bisect.command(shas[8] .. ' ' .. shas[2] .. ' -- true')
    settled('is not an ancestor')
    assert.same(before, state())
    assert.same({}, leftovers())
  end)

  it('runs nothing in a project not trusted', function()
    trusted = false
    bisect.command(shas[1] .. ' -- true')
    settled('not trusted')
    assert.is_nil(bisect.current)
    assert.same({}, leftovers())
  end)

  it('removes only worktrees it made', function()
    local base = vim.fs.normalize(bisect.base())
    assert.is_true(bisect.owned(base .. '/0123abcd'))
    assert.is_false(bisect.owned(''))
    assert.is_false(bisect.owned(nil))
    assert.is_false(bisect.owned(base))
    assert.is_false(bisect.owned(base .. '/'))
    assert.is_false(bisect.owned(base .. '/../x'))
    assert.is_false(bisect.owned(base .. '-other/0123'))
    assert.is_false(bisect.owned(repo))
  end)

  it('reads the first bad commit of both log formats', function()
    assert.equals(
      'abc1',
      (bisect.parse_log("x\n# first 'bad' commit: [abc1] subject"))
    )
    assert.equals('abc2', (bisect.parse_log('# first bad commit: [abc2] s')))
    local sha, candidates = bisect.parse_log(
      "# possible first 'bad' commit: [aa] a\n# possible first bad commit: [bb] b"
    )
    assert.is_nil(sha)
    assert.same({ 'aa', 'bb' }, candidates)
  end)

  it('builds the check of the test under the cursor', function()
    h.write(repo .. '/py/pyproject.toml', {})
    h.write(repo .. '/py/tests/test_a.py', { 'def test_x():', '    pass' })
    vim.cmd.edit(repo .. '/py/tests/test_a.py')
    vim.bo.filetype = 'python'
    vim.api.nvim_win_set_cursor(0, { 2, 0 })
    local cmd = assert(bisect.test_command(repo))
    assert.matches('^cd py && pytest .*tests/test_a%.py::test_x$', cmd)
    assert.is_nil(bisect.test_command(dir .. '/elsewhere'))
  end)

  it('quotes a command for the shell', function()
    assert.equals('go', bisect.quote('go'))
    assert.equals("'a b'", bisect.quote('a b'))
    assert.equals([['it'\''s']], bisect.quote("it's"))
  end)
end)
