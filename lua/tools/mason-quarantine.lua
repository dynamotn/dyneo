--- A quarantine window in front of mason's package index
---
--- The rest of these dotfiles hold every freshly published package back for a
--- week before it may be installed -- `min-release-age` in `~/.npmrc`,
--- `minimumReleaseAge` in the bun and pnpm configurations, `exclude-newer` in
--- `uv.toml` -- so that a compromised release has time to be caught and pulled
--- before it lands on this machine. mason has no such setting.
---
--- It does not need one per package, though: mason resolves no versions of its
--- own. Every package in `github:mason-org/mason-registry` carries its version
--- in the purl of the registry snapshot, and the snapshot is whatever release
--- of the registry repository is current, refreshed daily. Hold that one
--- release back by a week and every version it pins is at least a week old,
--- whatever it is installed from -- npm, PyPI, a GitHub release, Go, Open VSX.
---
--- This is a mason provider, and the only one in the `providers` setting. It
--- answers for GitHub releases itself and hands every other question -- git
--- tags, which the refs API gives no date to age by, and the versions npm,
--- PyPI and the rest list -- to mason's own providers in turn.
---
--- It has to stand alone: mason asks the next provider whenever one fails, so
--- with mason's own listed behind it, a quarantine that could not answer --
--- rate limited, offline, or with nothing old enough -- would let the newest
--- snapshot through. A failure here stays a failure, and mason keeps the
--- snapshot it already has.
local M = {}

--- mason's own providers, asked in this order for what is not aged here
local UPSTREAM = { 'mason.providers.registry-api', 'mason.providers.client' }

--- `service.method` of the first upstream provider that answers it
---@param service string
---@param method string
---@return fun(...): Result
local function delegate(service, method)
  return function(...)
    local Result = require('mason-core.result')
    local errors = {}
    for _, module in ipairs(UPSTREAM) do
      local impl = vim.tbl_get(require(module), service, method)
      if impl then
        local ok, result = pcall(impl, ...)
        if ok and result:is_success() then return result end
        table.insert(errors, tostring(ok and result:err_or_nil() or result))
      end
    end
    return Result.failure(
      ('%s.%s: %s'):format(service, method, table.concat(errors, '; '))
    )
  end
end

--- `own` with every method it lacks handed to `delegate`
---@param service string
---@param own? table<string, function>
---@return table<string, function>
local function forward(service, own)
  return setmetatable(own or {}, {
    __index = function(methods, method)
      local impl = delegate(service, method)
      rawset(methods, method, impl)
      return impl
    end,
  })
end

--- The window every side of the quarantine is held to: the one the plugin
--- quarantine reads, so the two never disagree
---@return integer
function M.window() return require('tools.lazy-quarantine').window() end

--- Seconds since the epoch of a UTC timestamp as the GitHub API writes them
---
--- `os.time` reads its fields as local time, so what it returns for a UTC
--- timestamp is off by this machine's offset; the same conversion run on a
--- known instant measures that offset back out.
---@param timestamp string? e.g. `2026-09-28T07:21:33Z`
---@return integer?
local function epoch(timestamp)
  if type(timestamp) ~= 'string' then return nil end
  local year, month, day, hour, minute, second =
    timestamp:match('^(%d+)-(%d+)-(%d+)T(%d+):(%d+):(%d+)')
  if not year then return nil end
  local now = os.time()
  local offset =
    os.difftime(now, os.time(os.date('!*t', now) --[[@as osdateparam]]))
  return os.time({
    year = tonumber(year),
    month = tonumber(month),
    day = tonumber(day),
    hour = tonumber(hour),
    min = tonumber(minute),
    sec = tonumber(second),
    isdst = false,
  }) + offset
end

--- The releases out of `releases` that have been published long enough, in the
--- order they came in (the API lists them newest first)
---
--- A draft or a prerelease is dropped whatever its age, and so is a release
--- whose `published_at` cannot be read: an unreadable date is not an argument
--- for installing it.
---@param releases GitHubRelease[]
---@param now? integer Seconds since the epoch, for the specs
---@return GitHubRelease[]
function M.quarantined(releases, now)
  now = now or os.time()
  return vim.tbl_filter(function(release)
    if release.draft or release.prerelease then return false end
    local published = epoch(release.published_at)
    return published ~= nil and os.difftime(now, published) >= M.window()
  end, releases)
end

--- Releases per page, and how many pages are read at most
---
--- mason-org/mason-registry cuts a release per merged pull request, a dozen
--- and more a day, so a week of them need not fit in one page. Five pages is
--- five hundred releases, more than any repository Mason installs from cuts
--- in a week; past that, the lookup fails rather than reading on.
local PER_PAGE = 100
local MAX_PAGES = 5

--- One page of the releases of `repo`, newest first
---
--- Reached through `gh` when it is installed, which spends the user's own rate
--- limit and sees private repositories, and over plain HTTPS otherwise -- the
--- same two ways mason's own client provider asks.
---@async
---@param repo string e.g. `mason-org/mason-registry`
---@param page integer
---@return Result # Result<GitHubRelease[]>
local function page_of_releases(repo, page)
  local fetch = require('mason-core.fetch')
  local spawn = require('mason-core.spawn')
  local path = ('repos/%s/releases?per_page=%d&page=%d'):format(
    repo,
    PER_PAGE,
    page
  )
  return spawn
    .gh({ 'api', path, env = { CLICOLOR_FORCE = 0 } })
    :map(function(result) return result.stdout end)
    :or_else(
      function()
        return fetch(('https://api.github.com/%s'):format(path), {
          headers = {
            Accept = 'application/vnd.github.v3+json; q=1.0, application/json; q=0.8',
          },
        })
      end
    )
    :map_catching(vim.json.decode)
end

--- The releases of `repo` that are out of quarantine, newest first
---
--- Pages are read until one of them holds a release old enough, since the
--- newest ones are exactly the ones the quarantine drops.
---@async
---@param repo string
---@return Result # Result<GitHubRelease[]>
local function aged_releases(repo)
  local Result = require('mason-core.result')
  local aged = {}
  for page = 1, MAX_PAGES do
    local result = page_of_releases(repo, page)
    if result:is_failure() then
      if page == 1 then return result end
      break
    end
    local batch = result:get_or_nil() --[[@as GitHubRelease[] ]]
    vim.list_extend(aged, M.quarantined(batch))
    if #aged > 0 or #batch < PER_PAGE then break end
  end
  if #aged == 0 then
    return Result.failure(
      ('No release of %s is older than the %d day quarantine.'):format(
        repo,
        M.window() / 86400
      )
    )
  end
  return Result.success(aged)
end

M.github = forward('github', {
  ---@async
  ---@param repo string
  ---@return Result # Result<GitHubRelease>
  get_latest_release = function(repo)
    return aged_releases(repo):map(function(aged) return aged[1] end)
  end,

  ---@async
  ---@param repo string
  ---@return Result # Result<string[]>
  get_all_release_versions = function(repo)
    return aged_releases(repo):map(function(aged)
      return vim.tbl_map(function(release) return release.tag_name end, aged)
    end)
  end,
})

-- Every other service mason knows is passed through whole
for _, service in ipairs({
  'npm',
  'pypi',
  'rubygems',
  'packagist',
  'crates',
  'golang',
  'openvsx',
}) do
  M[service] = forward(service)
end

return M
