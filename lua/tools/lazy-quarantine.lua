--- A quarantine window in front of lazy.nvim's plugin updates
---
--- A plugin is as much of a supply chain as a package from npm or PyPI, and a
--- bigger one: whatever it has in it runs in this editor the next time Neovim
--- starts. The rest of these dotfiles hold a freshly published package back
--- for a week before it may be installed -- `min-release-age` in `~/.npmrc`,
--- `minimumReleaseAge` for bun and pnpm, `exclude-newer` in `uv.toml`, and
--- `tools.mason-quarantine` in front of Mason -- so that a compromised
--- release has time to be caught and pulled. lazy.nvim has no setting for it.
---
--- Every decision of what to check out -- `:Lazy update`, the hourly checker,
--- the update the UI offers -- goes through one function, `get_target`, so
--- that is where the window goes: `setup()` wraps it and hands back the
--- newest commit, or the newest release, that has been out long enough. What
--- lazy.nvim does with the target is untouched, so `:Lazy restore` still puts
--- the lockfile back commit for commit, and a pinned plugin stays where it is.
---
--- Nothing is held back that cannot be: a plugin whose history is younger
--- than the window -- a repository published this week -- is installed as
--- lazy.nvim resolved it, since the alternative is not installing it at all.
local M = {}

local notify = require('util.notify').titled('Quarantine')

--- The wait when `DyNeo.quarantine_window` says nothing, the same week the npm,
--- bun, pnpm and uv configurations give the rest of these dotfiles
local DEFAULT_WINDOW = 7 * 24 * 60 * 60

--- The window every side of the quarantine is held to
---
--- Read on each question rather than kept, so `per_machine` has the say it
--- has over every other global -- and so `:checkhealth dyneo` reports what is
--- in force rather than what was in force when this module first loaded.
---@return integer
function M.window()
  local configured = (rawget(_G, 'DyNeo') or {}).quarantine_window
  return type(configured) == 'number' and configured or DEFAULT_WINDOW
end

--- Run `git` in `dir` and hand back its output, or nil when it fails
---
--- A command that succeeds without saying anything -- `checkout` -- hands
--- back nil as well, which is what the second return value is for.
---@param dir string
---@param args string[]
---@return string? output
---@return boolean ran Whether git exited 0
local function git(dir, args)
  local command = { 'git', '-C', dir }
  vim.list_extend(command, args)
  local result =
    require('util.system').sync(command, { text = true, timeout = 10000 })
  if result.code ~= 0 then return nil, false end
  local out = vim.trim(result.stdout or '')
  return out ~= '' and out or nil, true
end

--- What git said about commits, kept across sessions
---
--- lazy.nvim's checker asks for the target of every plugin right after
--- startup, on the main loop: a `git log` each is over half a second of a
--- frozen editor. `times` holds when each commit was made, which never
--- changes. `ancestors` holds the aged ancestor of a tip and the cutoff it was
--- found for; it is reused for `M.ANCESTOR_REUSE` seconds of a moving cutoff,
--- which can only hold a commit back longer, never let one through early.
--- `tips` holds, per plugin directory and oldest first, each target lazy.nvim
--- resolved and when this machine first saw it: unlike a commit date, that
--- is not up to whoever pushed the commit.
---@class DyQuarantineCache
---@field times table<string, integer>
---@field ancestors table<string, { commit: string, cutoff: integer }>
---@field tips table<string, { commit: string, at: integer }[]>

---@type DyQuarantineCache?
local cache
local cache_dirty = false

--- How long a found ancestor stands before git is asked again
M.ANCESTOR_REUSE = 6 * 60 * 60

---@return string
function M.cache_file()
  return vim.fs.joinpath(
    vim.fn.stdpath('state') --[[@as string]],
    'dyneo',
    'quarantine-cache.json'
  )
end

---@return DyQuarantineCache
local function load_cache()
  if cache then return cache end
  cache = { times = {}, ancestors = {}, tips = {} }
  local file = io.open(M.cache_file(), 'r')
  if not file then return cache end
  local ok, decoded = pcall(vim.json.decode, file:read('*a'))
  file:close()
  if not ok or type(decoded) ~= 'table' then return cache end
  for hash, time in
    pairs(type(decoded.times) == 'table' and decoded.times or {})
  do
    if type(time) == 'number' then cache.times[hash] = time end
  end
  for hash, found in
    pairs(type(decoded.ancestors) == 'table' and decoded.ancestors or {})
  do
    if
      type(found) == 'table'
      and type(found.commit) == 'string'
      and type(found.cutoff) == 'number'
    then
      cache.ancestors[hash] = found
    end
  end
  for dir, tips in pairs(type(decoded.tips) == 'table' and decoded.tips or {}) do
    if type(tips) == 'table' then
      cache.tips[dir] = vim.tbl_filter(
        function(tip)
          return type(tip) == 'table'
            and type(tip.commit) == 'string'
            and type(tip.at) == 'number'
        end,
        tips
      )
    end
  end
  return cache
end

--- Write the cache once the current batch of questions is answered
local function save_cache()
  if cache_dirty then return end
  cache_dirty = true
  vim.schedule(function()
    cache_dirty = false
    local path = M.cache_file()
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    local file = io.open(path, 'w')
    if not file then return end
    file:write(vim.json.encode(cache or {}))
    file:close()
  end)
end

--- `rev` when it is a full commit hash, the only name that never moves
---@param rev string
---@return string?
local function full_hash(rev)
  return #rev == 40 and rev:match('^%x+$') and rev or nil
end

--- When `rev` was committed, in seconds since the epoch
---@param dir string
---@param rev string
---@return integer?
---@return boolean ran Whether git could answer
local function committed_at(dir, rev)
  local hash = full_hash(rev)
  local times = load_cache().times
  if hash and times[hash] then return times[hash], true end
  local out, ran = git(dir, { 'log', '-1', '--format=%ct', rev })
  local time = tonumber(out)
  if hash and time then
    times[hash] = time
    save_cache()
  end
  return time, ran
end

--- Whether `rev` has been in the repository for longer than the window
---@param dir string
---@param rev string
---@param now integer
---@return boolean
---@return boolean ran Whether git could answer
local function aged(dir, rev, now)
  local committed, ran = committed_at(dir, rev)
  return committed ~= nil and os.difftime(now, committed) >= M.window(), ran
end

--- The newest ancestor of `rev` that is out of quarantine
---
--- `--until` goes by commit date, which is what the window is about: a commit
--- rewritten or merged today is new to this machine whenever it was written.
---@param dir string
---@param rev string
---@param now integer
---@return string?
---@return boolean ran Whether git could answer
local function aged_ancestor(dir, rev, now)
  local cutoff = now - M.window()
  local hash = full_hash(rev)
  local ancestors = load_cache().ancestors
  local found = hash and ancestors[hash]
  if
    found
    and cutoff >= found.cutoff
    and cutoff - found.cutoff < M.ANCESTOR_REUSE
  then
    return found.commit, true
  end
  local commit, ran = git(dir, {
    'log',
    '-1',
    -- The main line only: a branch merged today has commits of last week,
    -- and none of them was ever checked out upstream on its own
    '--first-parent',
    '--until=' .. os.date('!%Y-%m-%dT%H:%M:%S+00:00', cutoff),
    '--format=%H',
    rev,
  })
  if hash and commit then
    ancestors[hash] = { commit = commit, cutoff = cutoff }
    save_cache()
  end
  return commit, ran
end

--- Note `commit` as the tip of `dir` at `now`, and hand back the newest tip
--- first seen at least a window ago: nil until this machine has watched the
--- plugin for that long
---@param dir string
---@param commit string
---@param now integer
---@return { commit: string, at: integer }?
local function watched(dir, commit, now)
  local tips = load_cache().tips
  local list = tips[dir] or {}
  tips[dir] = list
  if not list[#list] or list[#list].commit ~= commit then
    table.insert(list, { commit = commit, at = now })
    save_cache()
  end
  local cutoff = now - M.window()
  local newest = 0
  for index, tip in ipairs(list) do
    if tip.at <= cutoff then newest = index end
  end
  -- What came before the newest aged tip no longer decides anything
  if newest > 1 then
    for _ = 1, newest - 1 do
      table.remove(list, 1)
    end
    save_cache()
  end
  return newest > 0 and list[1] or nil
end

--- Seconds until a target lazy.nvim proposes clears the window
---
--- Its commit date has to age. So does the time this machine first saw it
--- as the tip, when it saw another tip before: `M.target` then holds on to
--- that one until the new tip has been watched for a window.
---@param dir string
---@param commit string
---@param now integer
---@return integer
local function clears(dir, commit, now)
  local since = committed_at(dir, commit) or now
  local tips = load_cache().tips[dir] or {}
  for index, tip in ipairs(tips) do
    if tip.commit == commit and index > 1 then
      since = math.max(since, tip.at)
    end
  end
  return math.max(0, math.floor(since + M.window() - now + 0.5))
end

--- Whether a failing git was reported this session
local warned = false

--- What to check out when git cannot say how old `target` is: the commit
--- already there, since a check that cannot run must not let anything
--- through. A plugin not cloned yet has nothing to stay on.
---@param plugin LazyPlugin
---@param target GitInfo
---@param quiet? boolean Nothing failed: there is just nothing to move to
---@return GitInfo
local function stay(plugin, target, quiet)
  if not quiet and not warned then
    warned = true
    notify(
      ('git failed in `%s`: plugins stay where they are'):format(plugin.dir),
      vim.log.levels.WARN
    )
  end
  local ok, Git = pcall(require, 'lazy.manage.git')
  return ok and Git.info(plugin.dir) or target
end

--- The target lazy.nvim should check out instead of `target`
---
--- `releases` is only asked for when the target is a release -- the `stable`
--- channel -- and lists the ones matching the plugin's `version`, newest
--- first, as `{ tag = ..., commit = ... }`.
---@param plugin LazyPlugin
---@param target GitInfo?
---@param releases? fun(): { tag: string, commit: string?, version: table? }[]
---@param now? integer Seconds since the epoch, for the specs
---@return GitInfo?
function M.target(plugin, target, releases, now)
  if not target or not target.commit then return target end
  -- A plugin held at a commit, a tag or a pin is already where it was told to
  -- be, and a local one is the user's own working copy.
  if plugin.pin or plugin.commit or plugin.tag then return target end
  if plugin._ and plugin._.is_local then return target end

  now = now or os.time()
  -- A commit date says nothing a pusher cannot set: a target this machine
  -- first saw inside the window gives way to the newest one it saw before
  local seen = watched(plugin.dir, target.commit, now)
  if seen and seen.commit ~= target.commit then
    if not target.tag then
      target = vim.tbl_extend('force', target, { commit = seen.commit })
    else
      local release = vim.iter(releases and releases() or {}):find(
        function(release) return release.commit == seen.commit end
      )
      if not release then return stay(plugin, target, true) end
      target = vim.tbl_extend('force', target, {
        tag = release.tag,
        version = release.version,
        commit = release.commit,
      })
    end
  end

  local is_aged, ran = aged(plugin.dir, target.commit, now)
  if not ran then return stay(plugin, target) end
  if is_aged then return target end

  if target.tag then
    for _, release in ipairs(releases and releases() or {}) do
      if release.commit then
        local old, asked = aged(plugin.dir, release.commit, now)
        if not asked then return stay(plugin, target) end
        if old then
          return vim.tbl_extend('force', target, {
            tag = release.tag,
            version = release.version,
            commit = release.commit,
          })
        end
      end
    end
    -- No release of the range is old enough: what is checked out stays.
    -- Only a plugin with nothing cloned yet takes the fresh one, since the
    -- alternative is not installing it at all.
    local ok, Git = pcall(require, 'lazy.manage.git')
    local current = ok and Git.info(plugin.dir)
    if current then return current end
    notify(
      ('No release of `%s` has cleared the window: installing %s, nothing older is cloned'):format(
        plugin.name,
        target.tag
      ),
      vim.log.levels.WARN
    )
    return target
  end

  local commit, walked = aged_ancestor(plugin.dir, target.commit, now)
  if not walked then return stay(plugin, target) end
  if not commit then return target end
  return vim.tbl_extend('force', target, { commit = commit })
end

--- The releases of `plugin` matching the version its spec asks for, newest
--- first, as `M.target` wants them
---
--- The same spec `get_target` resolved the release from, so the window only
--- ever moves to an older release of the range asked for, never out of it.
---@param plugin LazyPlugin
---@return fun(): { tag: string, commit: string?, version: table? }[]
local function releases_of(plugin)
  return function()
    local Config = require('lazy.core.config')
    local Git = require('lazy.manage.git')
    local spec = (plugin.version == nil and plugin.branch == nil)
        and Config.options.defaults.version
      or plugin.version
    local versions = Git.get_versions(plugin.dir, spec or '*')
    table.sort(versions, function(a, b) return b < a end)
    return vim.tbl_map(
      function(version)
        return {
          tag = version.tag,
          version = version,
          commit = Git.ref(plugin.dir, 'tags/' .. version.tag),
        }
      end,
      versions
    )
  end
end

--- The wrapper `setup` put in place, and lazy.nvim's own resolution under it
---@type function?
local wrapper
---@type function?
local resolve

--- Whether lazy.nvim is still calling that wrapper
---
--- `get_target` is private to lazy.nvim, so a release that renames it would
--- leave the window in place and reaching nothing. `:checkhealth dyneo` asks
--- here rather than assuming the patch held.
---@return boolean
function M.installed()
  local ok, Git = pcall(require, 'lazy.manage.git')
  return ok and wrapper ~= nil and Git.get_target == wrapper
end

--- Hold a freshly cloned lazy.nvim back to the window as well
---
--- The bootstrap in `config.lazy` clones lazy.nvim itself and would take
--- whatever was released that morning: the one checkout the window cannot
--- reach the usual way, since lazy.nvim has to be on the runtimepath before
--- it can hold anything back. Once the clone is there it is an ordinary git
--- repository, so the same walk applies -- detached at the newest commit that
--- has been out long enough, which lazy.nvim then manages from.
---@param dir string Where lazy.nvim was cloned
---@param now? integer Seconds since the epoch, for the specs
---@return string? commit The commit checked out, or nil when it stayed put
function M.bootstrap(dir, now)
  local head = git(dir, { 'rev-parse', 'HEAD' })
  if not head then return nil end
  local target = M.target(
    { dir = dir, name = 'lazy.nvim' },
    { commit = head },
    nil,
    now
  )
  if not target or target.commit == head then return nil end
  local _, ran = git(dir, { 'checkout', '--quiet', '--detach', target.commit })
  return ran and target.commit or nil
end

--- The plugins the window is holding back right now
---
--- Asked of lazy.nvim's own resolution and of the window side by side, so a
--- row is only there when the two disagree. A `git log` per plugin, which is
--- why this is a command and not something the statusline could call.
---@param now? integer Seconds since the epoch, for the specs
---@return { name: string, held: string, available: string, clears: integer }[]
function M.held(now)
  now = now or os.time()
  if not resolve then return {} end
  local ok_config, Config = pcall(require, 'lazy.core.config')
  if not ok_config then return {} end

  local rows = {}
  for name, plugin in pairs(Config.plugins or {}) do
    local state = plugin._ or {}
    if state.installed and not state.is_local then
      local ok, target = pcall(resolve, plugin)
      if ok and target and target.commit then
        local held = M.target(plugin, target, releases_of(plugin), now)
        if held and held.commit ~= target.commit then
          table.insert(rows, {
            name = name,
            held = held.tag or held.commit:sub(1, 7),
            available = target.tag or target.commit:sub(1, 7),
            clears = clears(plugin.dir, target.commit, now),
          })
        end
      end
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

---@class DyPendingUpdate
---@field name string
---@field dir string
---@field from string The commit checked out
---@field to string The commit lazy.nvim would update to
---@field held boolean Whether the quarantine is holding it back
---@field clears integer Seconds until it no longer is

--- Every plugin whose checkout is behind what lazy.nvim would update it to
---
--- Held back or not: a commit out of quarantine lands on the next `:Lazy
--- update` as unread as one still in it, so `:DyQuarantine review` reads
--- both. `to` is lazy.nvim's own target, not the window's -- the review is
--- of everything on its way, before the window lets it through.
---@param now? integer Seconds since the epoch, for the specs
---@return DyPendingUpdate[]
function M.pending(now)
  now = now or os.time()
  if not resolve then return {} end
  local ok_config, Config = pcall(require, 'lazy.core.config')
  if not ok_config then return {} end

  ---@type DyPendingUpdate[]
  local rows = {}
  for name, plugin in pairs(Config.plugins or {}) do
    local state = plugin._ or {}
    if state.installed and not state.is_local then
      local ok, target = pcall(resolve, plugin)
      -- Read off `.git` by lazy.nvim: a process per plugin would freeze
      -- the editor before the review opens
      local head = ok
        and target
        and target.commit
        and require('lazy.manage.git').info(plugin.dir)
      head = head and head.commit
      if head and head ~= target.commit then
        local held = M.target(plugin, target, releases_of(plugin), now)
        table.insert(rows, {
          name = name,
          dir = plugin.dir,
          from = head,
          to = target.commit,
          held = held ~= nil and held.commit ~= target.commit,
          clears = clears(plugin.dir, target.commit, now),
        })
      end
    end
  end
  table.sort(rows, function(a, b) return a.name < b.name end)
  return rows
end

--- What `:DyQuarantine` completes its first argument with
local SUBCOMMANDS = { 'review' }

--- What `:DyQuarantine` completes the word being typed with
---@param line string The command line so far
---@return string[]
local function complete(_, line)
  local words = vim.split(line, '%s+', { trimempty = true })
  -- The word being typed counts once something of it is there
  local done = #words - (line:sub(-1) == ' ' and 0 or 1)
  if done <= 1 then return SUBCOMMANDS end
  if words[2] == 'review' and done == 2 then
    local ok, Config = pcall(require, 'lazy.core.config')
    local names = ok and vim.tbl_keys(Config.plugins or {}) or {}
    table.sort(names)
    return names
  end
  return {}
end

--- `:DyQuarantine`, and `:DyQuarantine review [{plugin}]`
---
--- The window is otherwise invisible: `:Lazy` shows a plugin as up to date
--- when it is a week behind on purpose, and nothing says which plugins those
--- are or how long is left. `review` reads what the updates on their way
--- would bring in, see `tools.plugin-review`.
function M.command()
  vim.api.nvim_create_user_command('DyQuarantine', function(args)
    if args.fargs[1] == 'review' then
      return require('tools.plugin-review').show(
        M.pending(),
        M.window(),
        args.fargs[2]
      )
    elseif args.fargs[1] then
      return notify(
        'Unknown subcommand: ' .. args.fargs[1],
        vim.log.levels.ERROR
      )
    end
    local rows = M.held()
    if #rows == 0 then
      return notify('Nothing is being held back', vim.log.levels.INFO)
    end
    local lines = vim.tbl_map(function(row)
      local hours = math.ceil(row.clears / 3600)
      local left = hours > 24 and ('%d days'):format(math.ceil(hours / 24))
        or ('%d hours'):format(hours)
      return ('- %s: on %s, %s waits %s'):format(
        row.name,
        row.held,
        row.available,
        left
      )
    end, rows)
    notify(
      ('Held back for %d days:\n'):format(M.window() / 86400)
        .. table.concat(lines, '\n'),
      vim.log.levels.INFO
    )
  end, {
    nargs = '*',
    complete = complete,
    desc = 'Plugins the release quarantine is holding back, or a review of '
      .. 'what the updates bring',
  })
end

--- Put the window in front of lazy.nvim's target resolution
---
--- Called before `require('lazy').setup()`, since that already installs what
--- is missing.
function M.setup()
  local Git = require('lazy.manage.git')
  resolve = Git.get_target

  ---@param plugin LazyPlugin
  Git.get_target = function(plugin)
    return M.target(plugin, resolve(plugin), releases_of(plugin))
  end
  wrapper = Git.get_target
  M.command()
end

return M
