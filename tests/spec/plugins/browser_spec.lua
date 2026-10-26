local h = require('helpers')

describe('plugins.integration.browser: open.nvim', function()
  local restore

  --- The open.nvim spec, read with `$JIRA_URL` set to `url`
  ---@param url? string
  ---@return table
  local function spec(url)
    restore = h.stub(vim.env, 'JIRA_URL', url)
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/integration/browser.lua'))
    do
      if plugin[1] == 'ofirgall/open.nvim' then return plugin end
    end
    error('no open.nvim spec')
  end

  before_each(function() h.globals() end)
  after_each(function() restore() end)

  it(
    'opens no Jira without `$JIRA_URL`',
    function() assert.same({}, spec(nil).opts.self_defined_openers) end
  )

  it('opens issue keys on the Jira of `$JIRA_URL`', function()
    local opener =
      spec('https://jira.example.com/browse/').opts.self_defined_openers[1]
    assert.same(
      { 'https://jira.example.com/browse/OPS-12' },
      opener.open_fn('see OPS-12 here')
    )
  end)

  it('maps `gx` in normal mode only', function()
    for _, key in ipairs(spec(nil).keys) do
      if key[1] == 'gx' then
        assert.is_true(
          key.mode == nil or key.mode == 'n',
          vim.inspect(key.mode)
        )
      end
    end
  end)
end)

describe('plugins.integration.browser: firenvim', function()
  local restores, specs, appname

  before_each(function()
    h.globals()
    appname = vim.env.NVIM_APPNAME
    DyNeo.firenvim_site_settings = {
      ['https://example.org/.*'] = { takeover = 'never' },
    }
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/integration/browser.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.g.firenvim_config = nil
    vim.env.NVIM_APPNAME = appname
  end)

  --- The spec of `name`
  ---@param name string
  ---@return table
  local function spec_of(name)
    for _, plugin in ipairs(specs) do
      if plugin[1] == name then return plugin end
    end
    error('no spec for ' .. name)
  end

  it('keeps the default site next to the per-machine ones', function()
    local sites = vim.g.firenvim_config.localSettings
    assert.equals('always', sites['.*'].takeover)
    assert.equals('never', sites['https://example.org/.*'].takeover)
    assert.is_false(spec_of('glacambre/firenvim').enabled)
  end)

  it('installs through the loaded plugin, and hides the bars', function()
    local loaded, installed
    vim.env.NVIM_APPNAME = nil
    table.insert(
      restores,
      h.stub(package.loaded, 'lazy', {
        load = function(opts) loaded = opts end,
      })
    )
    table.insert(
      restores,
      h.stub(vim.fn, 'firenvim#install', function(force) installed = force end)
    )
    local firenvim = spec_of('glacambre/firenvim')
    firenvim.build()
    assert.same({ plugins = { 'firenvim' }, wait = true }, loaded)
    assert.equals(0, installed)
    local laststatus, showtabline = vim.o.laststatus, vim.o.showtabline
    firenvim.config()
    assert.equals(0, vim.o.laststatus)
    assert.equals(0, vim.o.showtabline)
    vim.o.laststatus, vim.o.showtabline = laststatus, showtabline
  end)

  it('leaves the browser host to the default Neovim', function()
    local installed = false
    vim.env.NVIM_APPNAME = 'nvim-stable'
    table.insert(
      restores,
      h.stub(package.loaded, 'lazy', { load = function() end })
    )
    table.insert(
      restores,
      h.stub(vim.fn, 'firenvim#install', function() installed = true end)
    )
    spec_of('glacambre/firenvim').build()
    assert.is_false(installed)
  end)

  it('registers the Jira opener with open.nvim, and opens the word', function()
    local set_up, registered, opened = nil, {}, 0
    table.insert(
      restores,
      h.stub(package.loaded, 'open', {
        setup = function(opts) set_up = opts end,
        register_opener = function(opener) table.insert(registered, opener) end,
        open_cword = function() opened = opened + 1 end,
      })
    )
    local open = spec_of('ofirgall/open.nvim')
    local opts = {
      self_defined_openers = { { name = 'jira', open_fn = function() end } },
    }
    open.config(nil, opts)
    assert.equals(opts, set_up)
    assert.same(opts.self_defined_openers, registered)
    for _, key in ipairs(open.keys) do
      if key[1] == 'gx' then key[2]() end
    end
    assert.equals(1, opened)
  end)
end)
