local h = require('helpers')

describe('tools.ai.git', function()
  local git_tool, dir, cleanup, repo

  local function git(...)
    local result = vim
      .system(vim.list_extend({ 'git', '-C', repo }, { ... }), { text = true })
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  --- Hand `fn` a callback and wait for what it is called with
  ---@param fn fun(on_done: fun(...))
  ---@return any ...
  local function await(fn)
    local got
    fn(function(...) got = { ... } end)
    assert.is_true(vim.wait(5000, function() return got ~= nil end, 20))
    return unpack(got)
  end

  before_each(function()
    dir, cleanup = h.tmpdir()
    repo = dir .. '/repo'
    vim.fn.mkdir(repo, 'p')
    git('init', '-q', '-b', 'main')
    git('config', 'user.email', 'spec@example.com')
    git('config', 'user.name', 'Spec')
    h.write(repo .. '/a.txt', { 'one' })
    git('add', 'a.txt')
    git('commit', '-q', '-m', 'feat(a): add one')
    h.unload('tools.ai.git')
    git_tool = require('tools.ai.git')
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('finds the work tree of a file, and of its commit message', function()
    local bufnr = h.buffer({ name = repo .. '/a.txt' })
    assert.equals(repo, await(function(cb) git_tool.root(bufnr, cb) end))
    bufnr = h.buffer({ name = repo .. '/.git/COMMIT_EDITMSG' })
    assert.equals(repo, await(function(cb) git_tool.root(bufnr, cb) end))
  end)

  it('finds the work tree a linked worktree names in its gitdir', function()
    git('worktree', 'add', '-q', dir .. '/linked', '-b', 'linked')
    local bufnr =
      h.buffer({ name = repo .. '/.git/worktrees/linked/COMMIT_EDITMSG' })
    assert.equals(
      dir .. '/linked',
      await(function(cb) git_tool.root(bufnr, cb) end)
    )
  end)

  it('finds a linked worktree named relative to its gitdir', function()
    git('worktree', 'add', '-q', '--relative-paths', dir .. '/rel', '-b', 'rel')
    local bufnr =
      h.buffer({ name = repo .. '/.git/worktrees/rel/COMMIT_EDITMSG' })
    assert.equals(
      vim.uv.fs_realpath(dir .. '/rel'),
      vim.uv.fs_realpath(await(function(cb) git_tool.root(bufnr, cb) end))
    )
  end)

  it('says when a buffer is in no work tree', function()
    local bufnr = h.buffer({ name = dir .. '/loose.txt' })
    local root, err = await(function(cb) git_tool.root(bufnr, cb) end)
    assert.is_nil(root)
    assert.is_truthy(err:find('Not in a git work tree', 1, true))
  end)

  it('reads the log, and none from a failing git', function()
    assert.same(
      { 'feat(a): add one' },
      await(function(cb) git_tool.log(repo, { '--format=%s' }, cb) end)
    )
    assert.same({}, await(function(cb) git_tool.log(dir, { '-1' }, cb) end))
  end)

  it('refuses a sensitive file renamed to a plain name', function()
    local path = vim.env.PATH
    h.write(
      dir .. '/bin/betterleaks',
      { '#!/bin/sh', 'cat >/dev/null', 'echo "[]"' }
    )
    vim.fn.setfperm(dir .. '/bin/betterleaks', 'rwxr-xr-x')
    vim.env.PATH = dir .. '/bin:' .. path
    h.write(repo .. '/.env', { 'A=1' })
    git('add', '.env')
    git('commit', '-q', '-m', 'add env')
    git('mv', '.env', 'config.txt')
    local change, err = await(function(cb) git_tool.change(repo, nil, cb) end)
    vim.env.PATH = path
    assert.is_nil(change)
    assert.is_truthy(err:find('.env', 1, true), err)
  end)

  it('asks git about a .git folder that names no work tree', function()
    local bufnr =
      h.buffer({ name = repo .. '/.git/rebase-merge/git-rebase-todo' })
    local root, err = await(function(cb) git_tool.root(bufnr, cb) end)
    assert.is_nil(root)
    assert.is_truthy(err:find('Not in a git work tree', 1, true))
  end)

  it('passes on a git diff that fails', function()
    local change, err = await(function(cb) git_tool.change(dir, nil, cb) end)
    assert.is_nil(change)
    assert.is_string(err)

    -- The paths are listed, then the diff itself fails
    local path = vim.env.PATH
    local real = vim.fn.exepath('git')
    h.write(dir .. '/bin/git', {
      '#!/bin/sh',
      'for arg in "$@"; do',
      '  [ "$arg" = "--no-color" ] && { echo "boom" >&2; exit 1; }',
      'done',
      'exec "' .. real .. '" "$@"',
    })
    vim.fn.setfperm(dir .. '/bin/git', 'rwxr-xr-x')
    vim.env.PATH = dir .. '/bin:' .. path
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('add', 'a.txt')
    change, err = await(function(cb) git_tool.change(repo, nil, cb) end)
    vim.env.PATH = path
    assert.is_nil(change)
    assert.is_truthy(err:find('boom', 1, true), err)
  end)

  it('takes the default branch of origin as the base', function()
    local clone = dir .. '/clone'
    local result = vim
      .system({ 'git', 'clone', '-q', repo, clone }, { text = true })
      :wait()
    assert.equals(0, result.code, result.stderr)
    assert.equals(
      'origin/main',
      await(function(cb) git_tool.base(clone, cb) end)
    )
  end)

  it('falls back to a local main, and says when there is none', function()
    assert.equals('main', await(function(cb) git_tool.base(repo, cb) end))
    git('branch', '-m', 'main', 'trunk')
    local base, err = await(function(cb) git_tool.base(repo, cb) end)
    assert.is_nil(base)
    assert.is_truthy(err:find('No main branch', 1, true))
  end)

  it('takes a .gitlint or commitlint config as Conventional Commits', function()
    assert.is_false(git_tool.conventional(repo))
    h.write(repo .. '/.gitlint', { '[general]' })
    assert.is_true(git_tool.conventional(repo))
    vim.fn.delete(repo .. '/.gitlint')
    h.write(repo .. '/commitlint.config.js', { 'module.exports = {}' })
    assert.is_true(git_tool.conventional(repo))
  end)
end)
