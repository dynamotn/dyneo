local h = require('helpers')

describe('tools.review.git', function()
  local git, root, cleanup
  local sha = {}
  local saved_env = {}

  --- Run git in `dir`, failing the spec on a non-zero exit
  ---@param dir string
  ---@param ... string
  ---@return string
  local function sh(dir, ...)
    local out = vim.fn.system({ 'git', '-C', dir, ... })
    assert.is_equal(0, vim.v.shell_error, out)
    return vim.trim(out)
  end

  --- Call `start(cb)` and wait until `cb` ran; returns what it was given
  ---@param start fun(cb: function)
  ---@return any ...
  local function await(start)
    local got, done = nil, false
    start(function(...)
      got = vim.F.pack_len(...)
      done = true
    end)
    assert.is_true(vim.wait(15000, function() return done end, 10))
    return vim.F.unpack_len(got)
  end

  before_each(function()
    for _, name in ipairs({ 'GIT_CONFIG_GLOBAL', 'GIT_CONFIG_SYSTEM' }) do
      saved_env[name] = vim.uv.os_getenv(name) or false
      vim.uv.os_setenv(name, '/dev/null')
    end
    root, cleanup = h.tmpdir()
    sh(root, 'init', '-q', '--initial-branch=main')
    sh(root, 'config', 'user.name', 'T')
    sh(root, 'config', 'user.email', 't@example.com')
    sh(root, 'config', 'commit.gpgsign', 'false')
    local body = {}
    for i = 1, 20 do
      body[i] = 'line ' .. i
    end
    h.write(root .. '/a.txt', { 'one', 'two', 'three', 'four', 'five' })
    h.write(root .. '/b.txt', { 'b1', 'b2', 'b3' })
    h.write(root .. '/old.txt', body)
    h.write(root .. '/.gitattributes', { 'gen.txt linguist-generated' })
    sh(root, 'add', '-A')
    sh(root, 'commit', '-q', '-m', 'base')
    sha.base = sh(root, 'rev-parse', 'HEAD')

    sh(root, 'checkout', '-q', '-b', 'feature')
    h.write(root .. '/a.txt', { 'one', 'TWO', 'three', 'four', 'five', 'six' })
    h.write(root .. '/with space.txt', { 'x', 'y' })
    h.write(root .. '/gen.txt', { 'g' })
    sh(root, 'mv', 'old.txt', 'new.txt')
    h.write(root .. '/new.txt', vim.list_extend(vim.deepcopy(body), { 'more' }))
    local bin = assert(io.open(root .. '/bin.dat', 'wb'))
    bin:write('a\0b')
    bin:close()
    sh(root, 'add', '-A')
    sh(root, 'commit', '-q', '-m', 'feature')
    sha.feature = sh(root, 'rev-parse', 'HEAD')

    sh(root, 'checkout', '-q', 'main')
    h.write(root .. '/other.txt', { 'o' })
    sh(root, 'add', '-A')
    sh(root, 'commit', '-q', '-m', 'main moves on')
    sha.main = sh(root, 'rev-parse', 'HEAD')

    -- The same change on the moved base
    sh(root, 'checkout', '-q', '-b', 'rebased', 'main')
    sh(root, 'cherry-pick', sha.feature)
    sha.rebased = sh(root, 'rev-parse', 'HEAD')
    sh(root, 'checkout', '-q', 'main')

    h.unload('tools.review.git')
    git = require('tools.review.git')
  end)

  after_each(function()
    for name, value in pairs(saved_env) do
      if value then
        vim.uv.os_setenv(name, value)
      else
        vim.uv.os_unsetenv(name)
      end
    end
    cleanup()
  end)

  describe('merge_base', function()
    it('finds where the branches part', function()
      local base, err = await(
        function(cb) git.merge_base(root, 'main', 'feature', cb) end
      )
      assert.is_nil(err)
      assert.is_equal(sha.base, base)
    end)

    it('gives an error, not an empty answer, for an unknown rev', function()
      local base, err = await(
        function(cb) git.merge_base(root, 'main', 'nope', cb) end
      )
      assert.is_nil(base)
      assert.is_truthy(err and err ~= '')
    end)
  end)

  describe('files', function()
    local function by_path(files)
      local map = {}
      for _, f in ipairs(files) do
        map[f.path] = f
      end
      return map
    end

    it('lists status, counts, renames, binaries and attributes', function()
      local files, err = await(
        function(cb) git.files(root, sha.base, sha.feature, cb) end
      )
      assert.is_nil(err)
      local map = by_path(files)
      assert.is_equal(5, #files)
      assert.is_equal('M', map['a.txt'].status)
      assert.is_equal(2, map['a.txt'].added)
      assert.is_equal(1, map['a.txt'].removed)
      assert.is_equal('A', map['with space.txt'].status)
      assert.is_equal(2, map['with space.txt'].added)
      assert.is_equal('R', map['new.txt'].status)
      assert.is_equal('old.txt', map['new.txt'].old_path)
      assert.is_equal(1, map['new.txt'].added)
      assert.is_true(map['bin.dat'].binary)
      assert.is_false(map['a.txt'].binary)
      assert.is_true(map['gen.txt'].attrs.generated)
      assert.is_false(map['a.txt'].attrs.generated)
      assert.is_false(map['a.txt'].attrs.vendored)
      assert.is_nil(map['a.txt'].kind)
      assert.is_nil(map['a.txt'].risk)
    end)

    it('says why when git fails', function()
      local files, err = await(
        function(cb) git.files(root, 'nope', 'nada', cb) end
      )
      assert.is_nil(files)
      assert.is_truthy(err and err ~= '')
    end)

    it('says why when the directory is not a repository', function()
      local plain, clean = h.tmpdir()
      local files, err = await(function(cb) git.files(plain, 'a', 'b', cb) end)
      clean()
      assert.is_nil(files)
      assert.is_truthy(err and err ~= '')
    end)
  end)

  describe('blobs', function()
    it('maps paths to blob ids, absent ones left out', function()
      local blobs, err = await(
        function(cb)
          git.blobs(
            root,
            'feature',
            { 'a.txt', 'with space.txt', 'old.txt' },
            cb
          )
        end
      )
      assert.is_nil(err)
      assert.is_equal(sh(root, 'rev-parse', 'feature:a.txt'), blobs['a.txt'])
      assert.is_equal(
        sh(root, 'rev-parse', 'feature:with space.txt'),
        blobs['with space.txt']
      )
      assert.is_nil(blobs['old.txt'])
    end)

    it('gives an error for an unknown rev', function()
      local blobs, err = await(
        function(cb) git.blobs(root, 'nope', { 'a.txt' }, cb) end
      )
      assert.is_nil(blobs)
      assert.is_truthy(err)
    end)

    it('answers an empty list without running git', function()
      local blobs = await(function(cb) git.blobs(root, 'feature', {}, cb) end)
      assert.same({}, blobs)
    end)
  end)

  describe('hunks', function()
    it('gives the changed line ranges of both sides', function()
      local hunks, err = await(
        function(cb) git.hunks(root, sha.base, sha.feature, 'a.txt', cb) end
      )
      assert.is_nil(err)
      assert.same({ { 2, 2 } }, hunks.old)
      assert.same({ { 2, 2 }, { 6, 6 } }, hunks.new)
    end)

    it('reads a path with a space', function()
      local hunks = await(
        function(cb)
          git.hunks(root, sha.base, sha.feature, 'with space.txt', cb)
        end
      )
      assert.same({}, hunks.old)
      assert.same({ { 1, 2 } }, hunks.new)
    end)

    it('gives an error for an unknown rev', function()
      local hunks, err = await(
        function(cb) git.hunks(root, 'nope', 'nada', 'a.txt', cb) end
      )
      assert.is_nil(hunks)
      assert.is_truthy(err)
    end)
  end)

  describe('interdiff', function()
    it('finds nothing when a rebase changed no patch', function()
      local paths, err = await(
        function(cb)
          git.interdiff(root, sha.base, sha.feature, sha.main, sha.rebased, cb)
        end
      )
      assert.is_nil(err)
      assert.same({}, paths)
    end)

    it('finds the file edited since', function()
      sh(root, 'checkout', '-q', 'rebased')
      h.write(root .. '/b.txt', { 'b1', 'changed', 'b3' })
      sh(root, 'commit', '-q', '-am', 'edit b')
      local head = sh(root, 'rev-parse', 'HEAD')
      local paths, err = await(
        function(cb)
          git.interdiff(root, sha.base, sha.feature, sha.main, head, cb)
        end
      )
      assert.is_nil(err)
      assert.same({ 'b.txt' }, paths)
    end)

    it('counts a file on one side only', function()
      local paths = await(
        function(cb)
          git.interdiff(root, sha.base, sha.base, sha.base, sha.feature, cb)
        end
      )
      assert.same({
        'a.txt',
        'bin.dat',
        'gen.txt',
        'new.txt',
        'old.txt',
        'with space.txt',
      }, paths)
    end)

    it('gives an error for an unknown rev', function()
      local paths, err = await(
        function(cb) git.interdiff(root, 'x', 'y', 'z', 'w', cb) end
      )
      assert.is_nil(paths)
      assert.is_truthy(err)
    end)
  end)

  describe('diff', function()
    it('gives one diff per path', function()
      local diffs, err, cut = await(
        function(cb)
          git.diff(
            root,
            sha.base,
            sha.feature,
            { 'a.txt', 'with space.txt' },
            1024 * 1024,
            cb
          )
        end
      )
      assert.is_nil(err)
      assert.is_false(cut)
      assert.is_truthy(diffs['a.txt']:find('+TWO', 1, true))
      assert.is_truthy(diffs['with space.txt']:find('+x', 1, true))
    end)

    it('leaves out what does not fit and says so', function()
      local full = await(
        function(cb)
          git.diff(root, sha.base, sha.feature, { 'a.txt' }, 1024 * 1024, cb)
        end
      )
      local limit = #full['a.txt'] + 5
      local diffs, err, cut = await(
        function(cb)
          git.diff(
            root,
            sha.base,
            sha.feature,
            { 'a.txt', 'with space.txt', 'new.txt' },
            limit,
            cb
          )
        end
      )
      assert.is_nil(err)
      assert.is_true(cut)
      assert.is_truthy(diffs['a.txt'])
      assert.is_nil(diffs['with space.txt'])
      assert.is_nil(diffs['new.txt'])
    end)

    it('gives an error for an unknown rev', function()
      local diffs, err = await(
        function(cb) git.diff(root, 'x', 'y', { 'a.txt' }, 100, cb) end
      )
      assert.is_nil(diffs)
      assert.is_truthy(err)
    end)
  end)

  describe('refs', function()
    it('updates a ref and deletes those not kept', function()
      for _, name in ipairs({ 'pr-1', 'pr-2', 'pr-3' }) do
        local ok = await(
          function(cb)
            git.update_ref(root, 'refs/dyneo/review/' .. name, sha.main, cb)
          end
        )
        assert.is_true(ok)
      end
      sh(root, 'update-ref', 'refs/dyneo/other', sha.main)
      local deleted, err = await(
        function(cb)
          git.delete_refs(
            root,
            'refs/dyneo/review',
            { 'refs/dyneo/review/pr-2' },
            cb
          )
        end
      )
      assert.is_nil(err)
      assert.same(
        { 'refs/dyneo/review/pr-1', 'refs/dyneo/review/pr-3' },
        deleted
      )
      local left = sh(root, 'for-each-ref', '--format=%(refname)', 'refs/dyneo')
      assert.is_equal('refs/dyneo/other\nrefs/dyneo/review/pr-2', left)
    end)

    it('says why a ref cannot be set', function()
      local ok, err = await(
        function(cb) git.update_ref(root, 'refs/dyneo/x', 'nope', cb) end
      )
      assert.is_false(ok)
      assert.is_truthy(err and err ~= '')
    end)
  end)

  describe('fetch', function()
    it('brings refs from a remote into private refs', function()
      local remote, clean = h.tmpdir()
      sh(remote, 'init', '-q', '--bare')
      sh(root, 'push', '-q', remote, 'feature:refs/pull/1/head')
      sh(root, 'remote', 'add', 'up', remote)
      local ok, err = await(
        function(cb)
          git.fetch(root, 'up', { '+refs/pull/1/head:refs/dyneo/pr-1' }, cb)
        end
      )
      assert.is_nil(err)
      assert.is_true(ok)
      assert.is_equal(sha.feature, sh(root, 'rev-parse', 'refs/dyneo/pr-1'))
      clean()
    end)

    it('says why a fetch failed', function()
      local ok, err = await(
        function(cb) git.fetch(root, 'nowhere', { 'refs/x:refs/y' }, cb) end
      )
      assert.is_false(ok)
      assert.is_truthy(err and err ~= '')
    end)
  end)

  describe('worktrees', function()
    it('adds a detached worktree and removes a clean one', function()
      local parent, clean = h.tmpdir()
      local dir = parent .. '/wt'
      local ok, err = await(
        function(cb) git.worktree_add(root, dir, sha.feature, cb) end
      )
      assert.is_nil(err)
      assert.is_true(ok)
      assert.is_equal(1, vim.fn.filereadable(dir .. '/a.txt'))
      assert.is_equal('', sh(dir, 'branch', '--show-current'))
      ok, err = await(function(cb) git.worktree_remove(root, dir, cb) end)
      assert.is_nil(err)
      assert.is_true(ok)
      assert.is_equal(0, vim.fn.isdirectory(dir))
      clean()
    end)

    it('refuses to remove a dirty worktree', function()
      local parent, clean = h.tmpdir()
      local dir = parent .. '/wt'
      await(function(cb) git.worktree_add(root, dir, sha.feature, cb) end)
      h.write(dir .. '/a.txt', { 'edited by the reviewer' })
      local ok, err = await(function(cb) git.worktree_remove(root, dir, cb) end)
      assert.is_false(ok)
      assert.is_truthy(err and err ~= '')
      assert.is_equal(1, vim.fn.filereadable(dir .. '/a.txt'))
      clean()
    end)
  end)
end)
