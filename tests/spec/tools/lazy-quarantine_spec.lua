local h = require('helpers')

local DAY = 24 * 60 * 60
local now = os.time()

--- Run git in `dir`, failing the spec when it does
---@param dir string
---@param args string[]
---@param env? table<string, string>
---@return string
local function git(dir, args, env)
  local command = { 'git', '-C', dir }
  vim.list_extend(command, args)
  local result = vim
    .system(command, {
      text = true,
      env = vim.tbl_extend('force', {
        GIT_AUTHOR_NAME = 'Spec',
        GIT_AUTHOR_EMAIL = 'spec@example.com',
        GIT_COMMITTER_NAME = 'Spec',
        GIT_COMMITTER_EMAIL = 'spec@example.com',
      }, env or {}),
    })
    :wait(10000)
  assert.are.equal(
    0,
    result.code,
    table.concat(command, ' ') .. ': ' .. (result.stderr or '')
  )
  return vim.trim(result.stdout or '')
end

--- A repository whose commits were made `ages` seconds ago, oldest first
---@param ages integer[]
---@return string dir
---@return string[] commits In the order of `ages`
---@return fun() cleanup
local function repository(ages)
  local dir, cleanup = h.tmpdir()
  git(dir, { 'init', '--initial-branch=main', '--quiet' })
  local commits = {}
  for index, age in ipairs(ages) do
    local when = os.date('!%Y-%m-%dT%H:%M:%S+00:00', now - age)
    h.write(vim.fs.joinpath(dir, 'init.lua'), { '-- commit ' .. index })
    git(dir, { 'add', 'init.lua' })
    git(dir, { 'commit', '--quiet', '-m', 'commit ' .. index }, {
      GIT_AUTHOR_DATE = when,
      GIT_COMMITTER_DATE = when,
    })
    commits[index] = git(dir, { 'rev-parse', 'HEAD' })
  end
  -- Installed at the oldest, as a plugin is that lazy.nvim has just fetched
  -- the newer commits of: they are on `origin/main`, which is where it
  -- resolves a branch's target
  git(dir, { 'update-ref', 'refs/remotes/origin/main', 'HEAD' })
  git(dir, {
    'symbolic-ref',
    'refs/remotes/origin/HEAD',
    'refs/remotes/origin/main',
  })
  git(dir, { 'reset', '--quiet', '--hard', commits[1] })
  return dir, commits, cleanup
end

--- The target the quarantine picks for a branch plugin at `commits[#commits]`
---@param dir string
---@param commit string
---@param plugin? table Fields overriding the plugin
---@param releases? fun(): table[]
---@return table?
local function target(dir, commit, plugin, releases)
  h.unload('tools.lazy-quarantine')
  local quarantine = require('tools.lazy-quarantine')
  return quarantine.target(
    vim.tbl_extend('force', { dir = dir, name = 'spec.nvim' }, plugin or {}),
    { branch = 'main', commit = commit },
    releases,
    now
  )
end

describe('tools.lazy-quarantine', function()
  it('walks back to the newest commit out of quarantine', function()
    local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY, DAY })
    local picked = target(dir, commits[3])
    cleanup()
    assert.are.equal(commits[2], picked.commit)
    assert.are.equal('main', picked.branch)
  end)

  it('leaves a tip that has been out long enough alone', function()
    local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY })
    local picked = target(dir, commits[2])
    cleanup()
    assert.are.equal(commits[2], picked.commit)
  end)

  it('installs a repository younger than the window as it is', function()
    local dir, commits, cleanup = repository({ 2 * DAY, DAY })
    local picked = target(dir, commits[2])
    cleanup()
    assert.are.equal(commits[2], picked.commit)
  end)

  it('leaves a plugin held at a commit, a tag or a pin where it is', function()
    local dir, commits, cleanup = repository({ 30 * DAY, DAY })
    local held = {
      { pin = true },
      { commit = commits[2] },
      { tag = 'v1.0.0' },
      { _ = { is_local = true } },
    }
    local picked = vim.tbl_map(
      function(plugin) return target(dir, commits[2], plugin).commit end,
      held
    )
    cleanup()
    assert.are.same({ commits[2], commits[2], commits[2], commits[2] }, picked)
  end)

  it('takes the newest release out of quarantine', function()
    local dir, commits, cleanup = repository({ 30 * DAY, 9 * DAY, DAY })
    local releases = function()
      return {
        { tag = 'v3.0.0', commit = commits[3] },
        { tag = 'v2.0.0', commit = commits[2] },
        { tag = 'v1.0.0', commit = commits[1] },
      }
    end
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local picked = quarantine.target(
      { dir = dir, name = 'spec.nvim' },
      { branch = 'main', tag = 'v3.0.0', commit = commits[3] },
      releases,
      now
    )
    cleanup()
    assert.are.equal('v2.0.0', picked.tag)
    assert.are.equal(commits[2], picked.commit)
  end)

  it('stays on the checkout when no release is old enough', function()
    local dir, commits, cleanup = repository({ 3 * DAY, 2 * DAY, DAY })
    git(dir, { 'checkout', '--quiet', '--detach', commits[1] })
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local picked = quarantine.target(
      { dir = dir, name = 'spec.nvim' },
      { branch = 'main', tag = 'v3.0.0', commit = commits[3] },
      function()
        return {
          { tag = 'v3.0.0', commit = commits[3] },
          { tag = 'v2.0.0', commit = commits[2] },
        }
      end,
      now
    )
    cleanup()
    assert.are.equal(commits[1], picked.commit)
  end)

  it('installs a fresh release only when nothing is cloned', function()
    local dir, commits, cleanup = repository({ 2 * DAY, DAY })
    local empty, clean_empty = h.tmpdir()
    -- Answers on the age come from the cache, filled from the real clone
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local release = { tag = 'v2.0.0', commit = commits[2] }
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    quarantine.target(
      { dir = dir, name = 'spec.nvim' },
      { branch = 'main', tag = 'v2.0.0', commit = commits[2] },
      function() return { release } end,
      now
    )
    local picked = quarantine.target(
      { dir = empty, name = 'spec.nvim' },
      { branch = 'main', tag = 'v2.0.0', commit = commits[2] },
      function() return { release } end,
      now
    )
    restore()
    cleanup()
    clean_empty()
    assert.are.equal('v2.0.0', picked.tag)
    assert.is_truthy(notes[#notes]:find('nothing older is cloned', 1, true))
  end)

  it('installs a release on a fresh clone, never its default branch', function()
    -- The clone checked out `main`, a day past the only release
    local dir, commits, cleanup = repository({ 2 * DAY, DAY, 0 })
    local release = { tag = 'v2.0.0', commit = commits[2] }
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    local function pick()
      h.unload('tools.lazy-quarantine')
      return require('tools.lazy-quarantine').target(
        { dir = dir, name = 'spec.nvim', _ = { cloned = true } },
        { branch = 'main', tag = 'v2.0.0', commit = commits[2] },
        function() return { release } end,
        now
      )
    end
    local picked = pick()
    assert.is_truthy(notes[#notes]:find('has cleared the window', 1, true))
    -- Nor when git cannot say how old the release is
    local bin, clean_bin = h.tmpdir()
    h.write(bin .. '/git', { '#!/bin/sh', 'exit 128' })
    vim.fn.setfperm(bin .. '/git', 'rwxr-xr-x')
    local path = vim.env.PATH
    vim.env.PATH = bin .. ':' .. path
    os.remove(require('tools.lazy-quarantine').cache_file())
    local failed = pick()
    vim.env.PATH = path
    restore()
    clean_bin()
    cleanup()
    assert.are.equal('v2.0.0', picked.tag)
    assert.are.equal(commits[2], picked.commit)
    assert.are.equal(commits[2], failed.commit)
  end)

  describe('cache', function()
    it('answers the next session without asking git', function()
      local file = require('tools.lazy-quarantine').cache_file()
      os.remove(file)
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY, DAY })
      assert.are.equal(commits[2], target(dir, commits[3]).commit)
      assert.is_true(
        vim.wait(1000, function() return vim.uv.fs_stat(file) ~= nil end)
      )
      -- The repository is gone: only what was written down can answer
      cleanup()
      assert.are.equal(commits[2], target(dir, commits[3]).commit)
      assert.are.equal(commits[2], target(dir, commits[2]).commit)
    end)

    it('keeps what another Neovim wrote meanwhile', function()
      local file = require('tools.lazy-quarantine').cache_file()
      os.remove(file)
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY, DAY })
      -- Loaded, then another session writes its own watch of a plugin
      target(dir, commits[3])
      assert.is_true(
        vim.wait(1000, function() return vim.uv.fs_stat(file) ~= nil end)
      )
      local other = { commit = ('a'):rep(40), at = now - 3 * DAY }
      local written = vim.json.decode(table.concat(vim.fn.readfile(file), ''))
      written.tips[dir .. '/other'] = { other }
      written.tips[dir] = { { commit = commits[1], at = now - 20 * DAY } }
      vim.fn.writefile({ vim.json.encode(written) }, file)
      local quarantine = require('tools.lazy-quarantine')
      quarantine.target(
        { dir = dir, name = 'spec.nvim' },
        { branch = 'main', commit = commits[2] },
        nil,
        now
      )
      local saved
      assert.is_true(vim.wait(1000, function()
        saved = vim.json.decode(table.concat(vim.fn.readfile(file), ''))
        return #saved.tips[dir] > 1
      end))
      cleanup()
      assert.same({ other }, saved.tips[dir .. '/other'])
      assert.same(
        { commits[1], commits[3], commits[2] },
        vim.tbl_map(function(tip) return tip.commit end, saved.tips[dir])
      )
      assert.equals(now - 20 * DAY, saved.tips[dir][1].at)
      -- Written whole, then renamed into place
      assert.same(
        {},
        vim.fn.glob(
          vim.fs.dirname(file) .. '/quarantine-cache.json.*',
          false,
          true
        )
      )
    end)

    it('keeps pruned tips pruned when merging what is on disk', function()
      h.unload('tools.lazy-quarantine')
      local quarantine = require('tools.lazy-quarantine')
      local function tip(c, age) return { commit = c:rep(40), at = now - age } end
      local ours = {
        times = {},
        ancestors = {},
        tips = { dir = { tip('c', 10 * DAY), tip('d', 0) } },
      }
      quarantine.merge_cache(ours, {
        times = {},
        ancestors = {},
        tips = {
          dir = { tip('a', 30 * DAY), tip('b', 20 * DAY), tip('c', 10 * DAY) },
        },
      }, now)
      assert.same({ tip('c', 10 * DAY), tip('d', 0) }, ours.tips.dir)
    end)

    it('asks git again once the cutoff has moved on', function()
      local dir, commits, cleanup =
        repository({ 30 * DAY, 10 * DAY, 6 * DAY, DAY })
      assert.are.equal(commits[2], target(dir, commits[4]).commit)
      local quarantine = require('tools.lazy-quarantine')
      local later = quarantine.target(
        { dir = dir, name = 'spec.nvim' },
        { branch = 'main', commit = commits[4] },
        nil,
        now + 2 * DAY
      )
      cleanup()
      assert.are.equal(commits[3], later.commit)
    end)
  end)

  describe('window', function()
    it('waits a week unless a global says otherwise', function()
      h.unload('tools.lazy-quarantine')
      local quarantine = require('tools.lazy-quarantine')
      local before = DyNeo.quarantine_window
      DyNeo.quarantine_window = nil
      assert.are.equal(7 * DAY, quarantine.window())
      DyNeo.quarantine_window = 14 * DAY
      assert.are.equal(14 * DAY, quarantine.window())
      DyNeo.quarantine_window = before
    end)

    it('takes a plugin as it is when the wait is turned off', function()
      local dir, commits, cleanup = repository({ 30 * DAY, DAY })
      local before = DyNeo.quarantine_window
      DyNeo.quarantine_window = 0
      local picked = target(dir, commits[2])
      DyNeo.quarantine_window = before
      cleanup()
      assert.are.equal(commits[2], picked.commit)
    end)

    it('holds a plugin longer when the window is wider', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY })
      local before = DyNeo.quarantine_window
      DyNeo.quarantine_window = 14 * DAY
      local picked = target(dir, commits[2])
      DyNeo.quarantine_window = before
      cleanup()
      assert.are.equal(commits[1], picked.commit)
    end)
  end)

  describe('bootstrap', function()
    it('walks a fresh clone back to an aged commit', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY, DAY })
      -- A clone checks out the tip of the default branch
      git(dir, { 'reset', '--quiet', '--hard', commits[3] })
      h.unload('tools.lazy-quarantine')
      local moved = require('tools.lazy-quarantine').bootstrap(dir, now)
      local head = git(dir, { 'rev-parse', 'HEAD' })
      cleanup()
      assert.are.equal(commits[2], moved)
      assert.are.equal(commits[2], head)
    end)

    it('leaves a clone whose tip is old enough', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY })
      git(dir, { 'reset', '--quiet', '--hard', commits[2] })
      h.unload('tools.lazy-quarantine')
      local moved = require('tools.lazy-quarantine').bootstrap(dir, now)
      local head = git(dir, { 'rev-parse', 'HEAD' })
      cleanup()
      assert.is_nil(moved)
      assert.are.equal(commits[2], head)
    end)

    it('copes with a directory that is not a repository', function()
      local dir, cleanup = h.tmpdir()
      h.unload('tools.lazy-quarantine')
      local moved = require('tools.lazy-quarantine').bootstrap(dir, now)
      cleanup()
      assert.is_nil(moved)
    end)
  end)

  describe('held', function()
    local Config, Git, restore_plugins, restore_options, restore_target

    before_each(function()
      Config = require('lazy.core.config')
      Git = require('lazy.manage.git')
      -- `get_target` reads `defaults.version` for a plugin with no version of
      -- its own, and nothing has set lazy.nvim up in a spec.
      restore_options = h.stub(
        Config,
        'options',
        vim.tbl_deep_extend(
          'force',
          Config.options or {},
          { defaults = { version = false } }
        )
      )
      restore_plugins = h.stub(Config, 'plugins', {})
      restore_target = h.stub(Git, 'get_target', Git.get_target)
      h.unload('tools.lazy-quarantine')
      require('tools.lazy-quarantine').setup()
    end)

    after_each(function()
      restore_plugins()
      restore_options()
      restore_target()
      h.unload('tools.lazy-quarantine')
    end)

    it('lists a plugin whose tip is too fresh, and when it clears', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY, 2 * DAY })
      Config.plugins = {
        ['spec.nvim'] = {
          name = 'spec.nvim',
          dir = dir,
          _ = { installed = true },
        },
      }
      local rows = require('tools.lazy-quarantine').held(now)
      cleanup()
      assert.are.equal(1, #rows)
      assert.are.equal('spec.nvim', rows[1].name)
      assert.are.equal(commits[2]:sub(1, 7), rows[1].held)
      assert.are.equal(commits[3]:sub(1, 7), rows[1].available)
      -- Committed two days ago, so five of the seven are left
      assert.are.equal(5, math.floor(rows[1].clears / DAY))
    end)

    it('counts the wait from when it first saw an old-dated tip', function()
      -- The tip is dated 15 days back, but this machine first sees it now
      local dir, commits, cleanup = repository({ 30 * DAY, 20 * DAY, 15 * DAY })
      local quarantine = require('tools.lazy-quarantine')
      quarantine.target(
        { dir = dir, name = 'spec.nvim' },
        { branch = 'main', commit = commits[2] },
        nil,
        now - 10 * DAY
      )
      Config.plugins = {
        ['spec.nvim'] = {
          name = 'spec.nvim',
          dir = dir,
          _ = { installed = true },
        },
      }
      local rows = quarantine.held(now)
      cleanup()
      assert.are.equal(1, #rows)
      assert.are.equal(commits[2]:sub(1, 7), rows[1].held)
      assert.are.equal(7, math.floor(rows[1].clears / DAY + 0.5))
    end)

    it('says nothing about a plugin that is up to date', function()
      local dir, _, cleanup = repository({ 30 * DAY, 8 * DAY })
      Config.plugins = {
        ['spec.nvim'] = {
          name = 'spec.nvim',
          dir = dir,
          _ = { installed = true },
        },
      }
      local rows = require('tools.lazy-quarantine').held(now)
      cleanup()
      assert.are.same({}, rows)
    end)

    it('says what is held back, how long, and when nothing is', function()
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      vim.cmd('DyQuarantine')
      vim.cmd('DyQuarantine nope')
      local days, commits, cleanup = repository({ 30 * DAY, 8 * DAY, 2 * DAY })
      local hours, late, clean_hours =
        repository({ 30 * DAY, 8 * DAY, math.floor(6.5 * DAY) })
      Config.plugins = {
        ['days.nvim'] = {
          name = 'days.nvim',
          dir = days,
          _ = { installed = true },
        },
        ['hours.nvim'] = {
          name = 'hours.nvim',
          dir = hours,
          _ = { installed = true },
        },
      }
      vim.cmd('DyQuarantine')
      cleanup()
      clean_hours()
      restore()
      assert.are.same({
        'Nothing is being held back',
        'Unknown subcommand: nope',
        ('Held back for 7 days:\n- days.nvim: on %s, %s waits 5 days\n- hours.nvim: on %s, %s waits 12 hours'):format(
          commits[2]:sub(1, 7),
          commits[3]:sub(1, 7),
          late[2]:sub(1, 7),
          late[3]:sub(1, 7)
        ),
      }, notes)
      assert.are.same(
        {},
        vim.fn.getcompletion('DyQuarantine review x ', 'cmdline')
      )
    end)

    it('skips a plugin that is not installed, or is local', function()
      local dir, _, cleanup = repository({ 30 * DAY, DAY })
      Config.plugins = {
        ['gone.nvim'] = { name = 'gone.nvim', dir = dir, _ = {} },
        ['mine.nvim'] = {
          name = 'mine.nvim',
          dir = dir,
          _ = { installed = true, is_local = true },
        },
      }
      local rows = require('tools.lazy-quarantine').held(now)
      cleanup()
      assert.are.same({}, rows)
    end)
  end)

  describe('pending', function()
    local Config, Git, restore_plugins, restore_target

    before_each(function()
      Config = require('lazy.core.config')
      Git = require('lazy.manage.git')
      restore_plugins = h.stub(Config, 'plugins', {})
      restore_target = h.stub(Git, 'get_target', Git.get_target)
    end)
    after_each(function()
      restore_plugins()
      restore_target()
      h.unload('tools.lazy-quarantine')
    end)

    --- Set the quarantine up over a lazy.nvim resolving every plugin to
    --- `commit` of branch `main`
    ---@param commit string
    local function resolving_to(commit)
      Git.get_target = function() return { branch = 'main', commit = commit } end
      h.unload('tools.lazy-quarantine')
      require('tools.lazy-quarantine').setup()
    end

    it('lists a plugin behind its target, held or not', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 8 * DAY, 2 * DAY })
      git(dir, { 'checkout', '--quiet', '--detach', commits[1] })
      Config.plugins = {
        ['spec.nvim'] = {
          name = 'spec.nvim',
          dir = dir,
          _ = { installed = true },
        },
      }

      resolving_to(commits[3])
      local rows = require('tools.lazy-quarantine').pending(now)
      assert.are.equal(1, #rows)
      assert.are.same({
        name = 'spec.nvim',
        dir = dir,
        from = commits[1],
        to = commits[3],
        held = true,
      }, {
        name = rows[1].name,
        dir = rows[1].dir,
        from = rows[1].from,
        to = rows[1].to,
        held = rows[1].held,
      })
      assert.are.equal(5, math.floor(rows[1].clears / DAY))

      resolving_to(commits[2])
      rows = require('tools.lazy-quarantine').pending(now)
      cleanup()
      assert.is_false(rows[1].held)
      assert.are.equal(0, rows[1].clears)
    end)

    it('reads the releases a tagged target may fall back to', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 9 * DAY, DAY })
      for index, tag in ipairs({ 'v1.0.0', 'v2.0.0', 'v3.0.0' }) do
        git(dir, { 'tag', tag, commits[index] })
      end
      Git.get_target = function()
        return { branch = 'main', tag = 'v3.0.0', commit = commits[3] }
      end
      h.unload('tools.lazy-quarantine')
      local quarantine = require('tools.lazy-quarantine')
      assert.is_false(quarantine.installed())
      quarantine.setup()
      assert.is_true(quarantine.installed())
      -- A plugin naming no version takes the range lazy.nvim defaults to
      local restore_options = h.stub(
        Config,
        'options',
        vim.tbl_deep_extend(
          'force',
          Config.options or {},
          { defaults = { version = '*' } }
        )
      )
      local picked = Git.get_target({ dir = dir, name = 'spec.nvim' })
      restore_options()
      cleanup()
      assert.are.equal('v2.0.0', picked.tag)
      assert.are.equal(commits[2], picked.commit)
    end)

    it('leaves out a plugin already on its target', function()
      local dir, commits, cleanup = repository({ 30 * DAY, 2 * DAY })
      git(dir, { 'reset', '--quiet', '--hard', commits[2] })
      Config.plugins = {
        ['spec.nvim'] = {
          name = 'spec.nvim',
          dir = dir,
          _ = { installed = true },
        },
      }
      resolving_to(commits[2])
      local rows = require('tools.lazy-quarantine').pending(now)
      cleanup()
      assert.are.same({}, rows)
    end)
  end)

  describe(':DyQuarantine', function()
    after_each(function()
      pcall(vim.api.nvim_del_user_command, 'DyQuarantine')
      h.unload('tools.lazy-quarantine', 'tools.plugin-review')
    end)

    it('completes its subcommand, then the plugin to review', function()
      h.unload('tools.lazy-quarantine')
      require('tools.lazy-quarantine').command()
      local Config = require('lazy.core.config')
      local restore = h.stub(Config, 'plugins', {
        ['b.nvim'] = {},
        ['a.nvim'] = {},
      })
      local subcommands = vim.fn.getcompletion('DyQuarantine ', 'cmdline')
      local plugins = vim.fn.getcompletion('DyQuarantine review ', 'cmdline')
      -- Put back before asserting: a failure would leave lazy.nvim's plugins
      -- replaced for every spec after this one
      restore()
      assert.are.same({ 'review' }, subcommands)
      assert.are.same({ 'a.nvim', 'b.nvim' }, plugins)
    end)

    it('hands review its plugin', function()
      h.unload('tools.lazy-quarantine', 'tools.plugin-review')
      local review = require('tools.plugin-review')
      local shown
      local restore = h.stub(
        review,
        'show',
        function(rows, window, name) shown = { rows, window, name } end
      )
      require('tools.lazy-quarantine').command()
      vim.cmd('DyQuarantine review spec.nvim')
      restore()
      assert.are.same({ {}, 7 * DAY, 'spec.nvim' }, shown)
    end)
  end)

  it('holds back a commit it first saw today, whatever its date', function()
    -- The third commit is pushed today, its committer date set 15 days back
    local dir, commits, cleanup = repository({ 30 * DAY, 20 * DAY, 15 * DAY })
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local plugin = { dir = dir, name = 'spec.nvim' }
    local before = quarantine.target(
      plugin,
      { branch = 'main', commit = commits[2] },
      nil,
      now - 10 * DAY
    )
    local today = quarantine.target(
      plugin,
      { branch = 'main', commit = commits[3] },
      nil,
      now
    )
    local later = quarantine.target(
      plugin,
      { branch = 'main', commit = commits[3] },
      nil,
      now + 8 * DAY
    )
    cleanup()
    assert.are.equal(commits[2], before.commit)
    assert.are.equal(commits[2], today.commit)
    assert.are.equal(commits[3], later.commit)
  end)

  it('moves a release first seen today to the one seen before', function()
    local dir, commits, cleanup = repository({ 30 * DAY, 20 * DAY, 15 * DAY })
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local plugin = { dir = dir, name = 'spec.nvim' }
    local function releases()
      return {
        { tag = 'v3.0.0', commit = commits[3] },
        { tag = 'v2.0.0', commit = commits[2] },
      }
    end
    quarantine.target(
      plugin,
      { branch = 'main', tag = 'v2.0.0', commit = commits[2] },
      releases,
      now - 10 * DAY
    )
    local moved = quarantine.target(
      plugin,
      { branch = 'main', tag = 'v3.0.0', commit = commits[3] },
      releases,
      now
    )
    -- The release seen before is no longer among those the spec allows:
    -- the checkout stays
    local stayed = quarantine.target(
      plugin,
      { branch = 'main', tag = 'v3.0.0', commit = commits[3] },
      function() return { { tag = 'v3.0.0', commit = commits[3] } } end,
      now
    )
    cleanup()
    assert.are.equal('v2.0.0', moved.tag)
    assert.are.equal(commits[2], moved.commit)
    assert.are.equal(commits[1], stayed.commit)
  end)

  it('never moves a checkout back past what is installed', function()
    -- The second commit was seen 10 days ago; the third, dated 15 days back,
    -- first seen today, is what a clone checked out
    local dir, commits, cleanup = repository({ 30 * DAY, 20 * DAY, 15 * DAY })
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local plugin = { dir = dir, name = 'spec.nvim' }
    quarantine.target(
      plugin,
      { branch = 'main', commit = commits[2] },
      nil,
      now - 10 * DAY
    )
    git(dir, { 'reset', '--quiet', '--hard', commits[3] })
    local installed = quarantine.target(
      plugin,
      { branch = 'main', commit = commits[3] },
      nil,
      now
    )
    -- Between the commit the window allows and the target, it stays put too
    git(dir, { 'reset', '--quiet', '--hard', commits[2] })
    local behind = quarantine.target(
      plugin,
      { branch = 'main', commit = commits[3] },
      nil,
      now
    )
    cleanup()
    assert.are.equal(commits[3], installed.commit)
    assert.are.equal(commits[2], behind.commit)
  end)

  it('asks git once whether a checkout is newer than what is held', function()
    local dir, commits, cleanup = repository({ 30 * DAY, 20 * DAY, 2 * DAY })
    h.unload('tools.lazy-quarantine')
    local quarantine = require('tools.lazy-quarantine')
    local plugin = { dir = dir, name = 'spec.nvim' }
    -- The window holds the second, and the checkout is already past it
    git(dir, { 'reset', '--quiet', '--hard', commits[3] })
    local function pick()
      return quarantine.target(
        plugin,
        { branch = 'main', commit = commits[3] },
        nil,
        now
      ).commit
    end
    local asked = 0
    local system = require('util.system')
    local sync = system.sync
    local restore = h.stub(system, 'sync', function(cmd, opts)
      if vim.list_contains(cmd, 'merge-base') then asked = asked + 1 end
      return sync(cmd, opts)
    end)
    local first, again = pick(), pick()
    restore()
    cleanup()
    assert.are.equal(commits[3], first)
    assert.are.equal(commits[3], again)
    assert.are.equal(1, asked)
  end)

  it('stays on the checkout when git cannot answer', function()
    local dir, commits, cleanup = repository({ 30 * DAY, DAY })
    git(dir, { 'checkout', '--quiet', '--detach', commits[1] })
    local bin, clean_bin = h.tmpdir()
    h.write(bin .. '/git', { '#!/bin/sh', 'exit 128' })
    vim.fn.setfperm(bin .. '/git', 'rwxr-xr-x')
    local path = vim.env.PATH
    vim.env.PATH = bin .. ':' .. path
    local restore = h.stub(vim, 'notify', function() end)
    local picked = target(dir, commits[2])
    restore()
    vim.env.PATH = path
    clean_bin()
    cleanup()
    assert.are.equal(commits[1], picked.commit)
  end)

  it('copes with a directory that is not a repository', function()
    local dir, cleanup = h.tmpdir()
    local picked = target(dir, 'deadbeef')
    cleanup()
    assert.are.equal('deadbeef', picked.commit)
  end)
end)
