local h = require('helpers')

describe('config.globals', function()
  before_each(function() h.globals() end)

  it('sets the documented defaults', function()
    assert.is_true(DyNeo.dark_mode)
    assert.are.same(
      { enabled = false, day_start = 6, night_start = 18 },
      DyNeo.day_night
    )
    assert.is_false(DyNeo.is_gentoo)
    assert.is_false(DyNeo.used_full_plugins)
    assert.are.equal(
      vim.fn.has('nvim-0.13') == 1 and 'latest' or 'stable',
      DyNeo.plugin_channel
    )
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
