local h = require('helpers')

describe('config.globals', function()
  before_each(function() h.globals() end)

  it('sets the documented defaults', function()
    assert.is_true(DyNeo.dark_mode)
    assert.are.same(
      { enabled = false, day_start = 6, night_start = 18 },
      DyNeo.day_night
    )
    assert.is_false(DyNeo.used_full_plugins)
    assert.are.same({
      obsidian = false,
      leetcode = false,
      otter = false,
      firenvim = false,
      chezmoi = false,
    }, DyNeo.enabled_plugins)
    assert.are.same({}, DyNeo.bundle_languages)
    assert.are.same({}, DyNeo.completion_sources)
    assert.are.same({}, DyNeo.yaml_schema_dirs)
    assert.are.same({}, DyNeo.firenvim_site_settings)
    assert.are.same({
      target = 'avante',
      commit_command = { 'claude', '-p' },
      commit_timeout = 90 * 1000,
      local_only = {},
      local_providers = { 'ollama' },
    }, DyNeo.ai)
  end)

  describe('plugin_channel', function()
    ---@param prerelease string|nil What `vim.version()` reports
    local function globals_on(prerelease)
      local version = vim.version
      -- A module table that is also callable, like `vim.version` itself
      local fake = setmetatable({}, {
        __index = version,
        __call = function()
          local v = version()
          v.prerelease = prerelease
          return v
        end,
      })
      local restore = h.stub(vim, 'version', fake)
      h.globals()
      restore()
    end

    it('rides latest on a nightly', function()
      globals_on('dev')
      assert.are.equal('latest', DyNeo.plugin_channel)
    end)

    it('stays stable on a release, whatever its number', function()
      globals_on(nil)
      assert.are.equal('stable', DyNeo.plugin_channel)
    end)

    it('lets per_machine override it', function()
      globals_on('dev')
      local restore = h.stub(
        package.preload,
        'per_machine.config',
        function() DyNeo.plugin_channel = 'stable' end
      )
      h.unload('per_machine', 'per_machine.config')
      require('per_machine')
      restore()
      h.unload('per_machine', 'per_machine.config')
      assert.are.equal('stable', DyNeo.plugin_channel)
    end)
  end)

  it('needs a released Neovim on stable and a nightly on latest', function()
    DyNeo.plugin_channel = 'stable'
    assert.are.equal('0.12.0', DyNeo.neovim_floor())
    DyNeo.plugin_channel = 'latest'
    assert.are.equal('0.13.0', DyNeo.neovim_floor())
  end)

  it('enables every language of config.languages', function()
    local expected = vim.tbl_keys(require('config.languages'))
    table.sort(expected)
    -- In order as it is: `pairs` gives a new one each session
    assert.are.same(expected, DyNeo.enabled_languages)
  end)

  it('picks the test strategy from the multiplexer', function()
    local zellij = vim.env.ZELLIJ
    vim.env.ZELLIJ = nil
    h.globals()
    assert.are.equal('toggleterm', DyNeo.test_strategy)
    vim.env.ZELLIJ = '0'
    h.globals()
    assert.are.equal('zellij', DyNeo.test_strategy)
    vim.env.ZELLIJ = zellij
  end)

  it('reads the dev plugins path from NVIM_DEV_PLUGINS', function()
    local saved = vim.env.NVIM_DEV_PLUGINS
    vim.env.NVIM_DEV_PLUGINS = nil
    h.globals()
    assert.are.equal('~/Working/community/nvim', DyNeo.dev_plugins_path)
    vim.env.NVIM_DEV_PLUGINS = '/elsewhere'
    h.globals()
    assert.are.equal('/elsewhere', DyNeo.dev_plugins_path)
    vim.env.NVIM_DEV_PLUGINS = saved
  end)

  it('puts the dictionaries under XDG_CONFIG_HOME', function()
    local saved = vim.env.XDG_CONFIG_HOME
    vim.env.XDG_CONFIG_HOME = '/xdg'
    h.globals()
    assert.are.equal('/xdg/dictionaries', DyNeo.dictionaries_path)
    vim.env.XDG_CONFIG_HOME = saved
  end)

  describe('obsidian', function()
    it('lists every vault by name and path', function()
      DyNeo.obsidian.paths = { personal = '/a', work = '/b' }
      local vaults = DyNeo.obsidian.vaults()
      table.sort(vaults, function(x, y) return x.name < y.name end)
      assert.are.same({
        { name = 'personal', path = '/a' },
        { name = 'work', path = '/b' },
      }, vaults)
    end)

    it('reads the TODO note from the personal vault', function()
      DyNeo.obsidian.paths.personal = '/notes'
      assert.are.equal('/notes/01_Fleeting/TODO.md', DyNeo.obsidian.todo_path())
    end)
  end)

  describe('vim.print', function()
    it('goes through dd once a UI is attached and Snacks loaded', function()
      local seen = {}
      local restores = {
        h.stub(vim.api, 'nvim_list_uis', function() return { {} } end),
        h.stub(_G, 'dd', function(...) seen = { ... } end),
        h.stub(package.loaded, 'snacks', {}),
      }
      vim.api.nvim_exec_autocmds('UIEnter', { group = 'dy_print_ui' })
      vim.wait(100, function() return false end)
      local a, b = vim.print('x', 2)
      for i = #restores, 1, -1 do
        restores[i]()
      end
      assert.are.same({ 'x', 2 }, seen)
      assert.are.equal('x', a)
      assert.are.equal(2, b)
      -- The UI gone, the built-in is back
      vim.api.nvim_exec_autocmds('UILeave', { group = 'dy_print_ui' })
      vim.wait(100, function() return false end)
      seen = {}
      local restore = h.stub(_G, 'dd', function(...) seen = { ... } end)
      vim.print('y')
      restore()
      assert.are.same({}, seen)
    end)

    it(
      'stays the built-in without a UI and hands its arguments back',
      function()
        local called = false
        local restore = h.stub(_G, 'dd', function() called = true end)
        local a, b = vim.print('x', 2)
        restore()
        assert.is_false(called)
        assert.are.equal('x', a)
        assert.are.equal(2, b)
      end
    )
  end)
end)
