local h = require('helpers')

local DAY = 24 * 60 * 60
local now = os.time()

--- A GitHub release published `age` seconds ago
---@param tag string
---@param age integer
---@param opts? { draft?: boolean, prerelease?: boolean, published_at?: string }
---@return table
local function release(tag, age, opts)
  opts = opts or {}
  return {
    tag_name = tag,
    draft = opts.draft or false,
    prerelease = opts.prerelease or false,
    published_at = opts.published_at
      or os.date('!%Y-%m-%dT%H:%M:%SZ', now - age),
  }
end

--- The tags `quarantined` keeps out of `releases`
---@param releases table[]
---@return string[]
local function kept(releases)
  h.unload('tools.mason-quarantine')
  local quarantine = require('tools.mason-quarantine')
  return vim.tbl_map(
    function(r) return r.tag_name end,
    quarantine.quarantined(releases, now)
  )
end

describe('tools.mason-quarantine', function()
  it(
    'holds back releases younger than a week',
    function()
      assert.are.same(
        { 'old' },
        kept({ release('new', DAY), release('old', 8 * DAY) })
      )
    end
  )

  it(
    'keeps a release exactly a week old',
    function() assert.are.same({ 'week' }, kept({ release('week', 7 * DAY) })) end
  )

  it(
    'keeps the newest aged release first',
    function()
      assert.are.same(
        { 'newer', 'older' },
        kept({
          release('fresh', 2 * DAY),
          release('newer', 9 * DAY),
          release('older', 30 * DAY),
        })
      )
    end
  )

  it(
    'drops drafts and prereleases whatever their age',
    function()
      assert.are.same(
        {},
        kept({
          release('draft', 30 * DAY, { draft = true }),
          release('rc', 30 * DAY, { prerelease = true }),
        })
      )
    end
  )

  it(
    'drops a release whose date cannot be read',
    function()
      assert.are.same(
        {},
        kept({
          release('undated', 30 * DAY, { published_at = vim.NIL }),
          release('garbled', 30 * DAY, { published_at = 'last tuesday' }),
        })
      )
    end
  )

  it('follows the window a global sets', function()
    local before = DyNeo.quarantine_window
    DyNeo.quarantine_window = 14 * DAY
    local kept_wide =
      kept({ release('ten', 10 * DAY), release('old', 20 * DAY) })
    DyNeo.quarantine_window = 0
    local kept_off = kept({ release('fresh', 60) })
    DyNeo.quarantine_window = before
    assert.are.same({ 'old' }, kept_wide)
    assert.are.same({ 'fresh' }, kept_off)
  end)

  describe('as the only provider', function()
    local stubbed = {
      'mason-core.result',
      'mason-core.fetch',
      'mason-core.spawn',
      'mason.providers.registry-api',
      'mason.providers.client',
    }
    local calls, quarantine

    --- Just enough of mason's `Result` for the provider to run on
    local Result = {}
    Result.__index = Result
    function Result.success(value)
      return setmetatable({ ok = true, value = value }, Result)
    end
    function Result.failure(err)
      return setmetatable({ ok = false, err = err }, Result)
    end
    function Result:is_success() return self.ok end
    function Result:is_failure() return not self.ok end
    function Result:get_or_nil() return self.value end
    function Result:err_or_nil() return self.err end
    function Result:map(fn)
      return self.ok and Result.success(fn(self.value)) or self
    end
    Result.map_catching = Result.map
    function Result:or_else(fn) return self.ok and self or fn() end

    --- An upstream provider whose methods record the call and answer `answer`
    ---@param name string
    ---@param answer table<string, table> Result per `service.method`
    local function upstream(name, answer)
      local provider = {}
      for key, result in pairs(answer) do
        local service, method = key:match('^(%w+)%.(.+)$')
        provider[service] = provider[service] or {}
        provider[service][method] = function(...)
          table.insert(calls, { name, key, ... })
          return result
        end
      end
      package.loaded['mason.providers.' .. name] = provider
    end

    before_each(function()
      calls = {}
      package.loaded['mason-core.result'] = Result
      -- Every release lookup of the quarantine itself fails
      package.loaded['mason-core.spawn'] = {
        gh = function() return Result.failure('gh: rate limited') end,
      }
      package.loaded['mason-core.fetch'] = function()
        return Result.failure('fetch: offline')
      end
      upstream('registry-api', {
        ['github.get_latest_release'] = Result.success({ tag_name = 'new' }),
        ['github.get_latest_tag'] = Result.failure('api: down'),
        ['npm.get_all_versions'] = Result.success({ '1.0.0' }),
      })
      upstream('client', {
        ['github.get_latest_tag'] = Result.success({ tag = 'v1' }),
      })
      h.unload('tools.mason-quarantine')
      quarantine = require('tools.mason-quarantine')
    end)
    after_each(
      function() h.unload('tools.mason-quarantine', unpack(stubbed)) end
    )

    it('keeps a failed release lookup failed', function()
      local result = quarantine.github.get_latest_release('mason-org/x')
      assert.is_true(result:is_failure())
      assert.equals('fetch: offline', result:err_or_nil())
      assert.same({}, calls)
    end)

    it('reads pages until one holds an aged release', function()
      local pages = {}
      package.loaded['mason-core.spawn'] = {
        gh = function(args)
          local page = tonumber(args[2]:match('page=(%d+)$'))
          table.insert(calls, { 'gh', args[2] })
          local batch = pages[page]
          if not batch then return Result.failure('gh: no such page') end
          return Result.success({ stdout = vim.json.encode(batch) })
        end,
      }
      -- A full first page of fresh releases, the aged one on the second
      pages[1] = {}
      for index = 1, 100 do
        pages[1][index] = release('fresh' .. index, DAY)
      end
      pages[2] = {
        release('rc', 30 * DAY, { prerelease = true }),
        release('old', 30 * DAY),
      }
      assert.same(
        { 'old' },
        quarantine.github.get_all_release_versions('o/r'):get_or_nil()
      )
      assert.equals(2, #calls)
      assert.equals(
        'old',
        quarantine.github.get_latest_release('o/r'):get_or_nil().tag_name
      )

      -- Nothing old enough on a short page: a failure, never the newest
      pages = { { release('fresh', DAY) } }
      local result = quarantine.github.get_latest_release('o/r')
      assert.is_true(result:is_failure())
      assert.equals(
        'No release of o/r is older than the 7 day quarantine.',
        result:err_or_nil()
      )

      -- A later page that cannot be read ends the search with what was read
      pages = { pages[1] }
      for index = 2, 100 do
        pages[1][index] = release('fresh' .. index, DAY)
      end
      result = quarantine.github.get_all_release_versions('o/r')
      assert.is_true(result:is_failure())
      assert.matches('No release of o/r', result:err_or_nil())
    end)

    it('hands git tags to the first upstream that answers', function()
      local result = quarantine.github.get_latest_tag('o/r')
      assert.same({ tag = 'v1' }, result:get_or_nil())
      assert.same({
        { 'registry-api', 'github.get_latest_tag', 'o/r' },
        { 'client', 'github.get_latest_tag', 'o/r' },
      }, calls)
    end)

    it('passes every other service through', function()
      local result = quarantine.npm.get_all_versions('pkg')
      assert.same({ '1.0.0' }, result:get_or_nil())
    end)

    it('fails with every upstream error when none answers', function()
      local result = quarantine.pypi.get_all_versions('pkg')
      assert.is_true(result:is_failure())
      assert.matches('pypi.get_all_versions', result:err_or_nil())
    end)
  end)

  it('reads the timestamp as UTC, whatever the local zone is', function()
    local tz = vim.env.TZ
    for _, zone in ipairs({ 'UTC', 'Asia/Ho_Chi_Minh', 'America/Anchorage' }) do
      vim.env.TZ = zone
      -- A release that has been out for a week and a minute stays in, one
      -- that is a minute short of the week does not; a zone read as local
      -- time would move either of them by hours.
      assert.are.same(
        { 'just-aged' },
        kept({
          release('too-fresh', 7 * DAY - 60),
          release('just-aged', 7 * DAY + 60),
        }),
        zone
      )
    end
    vim.env.TZ = tz
  end)
end)
