local h = require('helpers')

describe('tools.debt', function()
  local debt, dir, root, cleanup, notes, restores, env

  -- 2026-01-15 12:00 UTC
  local NOW = 1768478400

  before_each(function()
    h.unload('tools.debt')
    debt = require('tools.debt')
    dir, cleanup = h.tmpdir()
    dir = vim.uv.fs_realpath(dir)
    root = dir .. '/proj'
    vim.fn.mkdir(root, 'p')
    notes = {}
    -- The user's global git config and hooks stay out of it
    env = {
      GIT_CONFIG_GLOBAL = vim.env.GIT_CONFIG_GLOBAL,
      GIT_CONFIG_NOSYSTEM = vim.env.GIT_CONFIG_NOSYSTEM,
      GIT_CEILING_DIRECTORIES = vim.env.GIT_CEILING_DIRECTORIES,
    }
    vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
    vim.env.GIT_CONFIG_NOSYSTEM = '1'
    vim.env.GIT_CEILING_DIRECTORIES = dir
    local time = os.time
    restores = {
      h.stub(vim, 'notify', function(msg, level, opts)
        -- Only its own: Neovim may say something of its log meanwhile
        if (opts or {}).title == 'DyNeo Debt' then
          table.insert(notes, { msg = msg, level = level })
        end
      end),
      h.stub(
        package.loaded,
        'util.root',
        setmetatable({}, { __call = function() return root end })
      ),
      h.stub(os, 'time', function(t)
        if t then return time(t) end
        return NOW
      end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    for key, value in pairs(env) do
      vim.env[key] = value
    end
    vim.fn.setqflist({})
    vim.cmd('silent! cclose')
    cleanup()
  end)

  local function git(args, extra)
    local result = vim
      .system(
        vim.list_extend({ 'git', '-c', 'commit.gpgsign=false' }, args),
        { cwd = root, env = extra }
      )
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  --- Commit everything as `name <email>` on `date`
  local function commit(name, email, date)
    git({ 'add', '-A' })
    git({ 'commit', '-q', '-m', date }, {
      GIT_AUTHOR_NAME = name,
      GIT_AUTHOR_EMAIL = email,
      GIT_COMMITTER_NAME = name,
      GIT_COMMITTER_EMAIL = email,
      GIT_AUTHOR_DATE = date .. 'T12:00:00Z',
      GIT_COMMITTER_DATE = date .. 'T12:00:00Z',
    })
  end

  local function append(file, lines)
    vim.fn.writefile(lines, root .. '/' .. file, 'a')
  end

  --- A repository with markers written over six years, one not committed
  local function history()
    git({ 'init', '-q' })
    git({ 'config', 'user.email', 'Me@Example.com' })
    append('a.lua', { '-- TODO: oldest one', 'local x = 1' })
    commit('Alice', 'alice@example.com', '2020-01-15')
    append('b.sh', { '# FIXME: middle' })
    append('a.lua', { '-- HACK: patched' })
    commit('Bob', 'bob@example.com', '2023-01-15')
    append('c.c', { '/* XXX: mine */', 'int TODOS = 1;' })
    commit('Me', 'me@example.com', '2025-01-15')
    append('b.sh', { '# TODO: work in progress' })
  end

  local function texts()
    return vim.tbl_map(function(item) return item.text end, vim.fn.getqflist())
  end

  --- Run `:DyDebt` with `args` and wait for the list
  local function run(args)
    vim.fn.setqflist({})
    local count = #notes
    debt.run(args)
    assert.is_true(vim.wait(10000, function() return #notes > count end))
    return texts()
  end

  it('reads the age of a time in calendar months', function()
    local t = os.time({ year = 2020, month = 1, day = 15, hour = 12 })
    local at = function(y, m, d)
      return os.time({ year = y, month = m, day = d, hour = 12 })
    end
    assert.equals('6y 0m', debt.age(t, at(2026, 1, 15)))
    assert.equals('3y 2m', debt.age(t, at(2023, 3, 20)))
    assert.equals('11m', debt.age(t, at(2021, 1, 14)))
    assert.equals('12d', debt.age(t, at(2020, 1, 27)))
  end)

  it(
    'finds the marker after a word boundary and trims a comment end',
    function()
      assert.same({ 'XXX', 'mine' }, { debt.marker('/* XXX: mine */') })
      assert.same({ 'FIXME', 'a' }, { debt.marker('x TODOS: y FIXME: a') })
      assert.is_nil(debt.marker('int TODOS = 1;'))
    end
  )

  it('lists the markers oldest first with ages and authors', function()
    history()
    local listed = run({})
    assert.same({
      '[TODO] 6y 0m · Alice · oldest one',
      -- Of the same age, by path and line
      '[HACK] 3y 0m · Bob · patched',
      '[FIXME] 3y 0m · Bob · middle',
      '[XXX] 1y 0m · Me · mine',
      '[TODO] 0d · not committed · work in progress',
    }, listed)
    local items = vim.fn.getqflist()
    assert.equals(root .. '/a.lua', vim.api.nvim_buf_get_name(items[1].bufnr))
    assert.equals(1, items[1].lnum)
    assert.equals(3, items[2].lnum)
    local summary = notes[#notes].msg
    assert.matches('5 markers %(TODO 2, FIXME 1, HACK 1, XXX 1%)', summary)
    assert.matches('median age 3y 0m', summary)
    assert.matches('oldest 6y 0m at a.lua:1', summary)
    -- The notification names places, never what the comments say
    assert.is_nil(summary:find('oldest one', 1, true))
  end)

  it('ages a file git does not track as not committed', function()
    history()
    append('new.lua', { '-- TODO: fresh' })
    local listed = run({ 'todo' })
    assert.same({
      '[TODO] 6y 0m · Alice · oldest one',
      '[TODO] 0d · not committed · work in progress',
      '[TODO] 0d · not committed · fresh',
    }, listed)
  end)

  it('keeps one keyword, or the markers of the user', function()
    history()
    assert.same({ '[FIXME] 3y 0m · Bob · middle' }, run({ 'FIXME' }))
    git({ 'config', 'user.email', 'me@example.com' })
    assert.same({ '[XXX] 1y 0m · Me · mine' }, run({ 'mine' }))
    assert.same({}, run({ 'mine', 'TODO' }))
    assert.matches('No marker matches', notes[#notes].msg)
  end)

  it('rejects an unknown argument', function()
    debt.run({ 'BUGS' })
    assert.matches('Unknown argument: BUGS', notes[1].msg)
    assert.equals(vim.log.levels.ERROR, notes[1].level)
  end)

  it('answers from its cache until HEAD changes', function()
    history()
    run({})
    local key = debt.cache[root].key
    -- A marker the cache cannot know: the scan is not read again
    debt.cache[root].scan.entries[1].text = 'cached'
    assert.equals('[TODO] 6y 0m · Alice · cached', run({})[1])
    append('d.lua', { '-- TODO: later' })
    commit('Bob', 'bob@example.com', '2025-06-15')
    local listed = run({})
    assert.are_not.equal(key, debt.cache[root].key)
    assert.equals('[TODO] 6y 0m · Alice · oldest one', listed[1])
    -- The commit took the line not committed before along
    assert.same({
      '[TODO] 7m · Bob · work in progress',
      '[TODO] 7m · Bob · later',
    }, vim.list_slice(listed, 5))
  end)

  it('lists the markers without ages outside a git repository', function()
    append('a.lua', { '-- TODO: loose', '-- HACK: also' })
    local listed = run({})
    table.sort(listed)
    assert.same({ '[HACK] · also', '[TODO] · loose' }, listed)
    assert.matches('no ages: not a git repository', notes[#notes].msg)
    assert.equals(vim.log.levels.WARN, notes[#notes].level)
    debt.run({ 'mine' })
    assert.is_true(
      vim.wait(
        5000,
        function()
          return notes[#notes].msg:match('`mine` needs git blame') ~= nil
        end
      )
    )
  end)
end)
