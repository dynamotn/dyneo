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

  --- The opener of `spec` named `name`
  ---@param plugin table
  ---@param name string
  ---@return table?
  local function opener(plugin, name)
    for _, o in ipairs(plugin.opts.self_defined_openers) do
      if o.name == name then return o end
    end
  end

  before_each(function() h.globals() end)
  after_each(function() restore() end)

  it(
    'opens no Jira without `$JIRA_URL`',
    function() assert.is_nil(opener(spec(nil), 'jira')) end
  )

  it('opens issue keys on the Jira of `$JIRA_URL`', function()
    local jira = opener(spec('https://jira.example.com/browse/'), 'jira')
    assert.same(
      { 'https://jira.example.com/browse/OPS-12' },
      jira.open_fn('see OPS-12 here')
    )
  end)

  it(
    'asks no web service what an `a/b` word is',
    function()
      assert.is_true(
        vim.list_contains(spec(nil).opts.disabled_openers, 'github')
      )
    end
  )

  describe('a quoted plugin name', function()
    local lazy, restore_lazy

    before_each(function()
      lazy = opener(spec(nil), 'lazy')
      restore_lazy = h.stub(package.loaded, 'lazy.core.config', {
        plugins = {
          ['open.nvim'] = {
            'ofirgall/open.nvim',
            url = 'https://github.com/ofirgall/open.nvim.git',
          },
          ['mine.nvim'] = {
            'me/mine.nvim',
            url = 'https://gitlab.com/me/mine.nvim.git',
          },
        },
      })
    end)
    after_each(function() restore_lazy() end)

    it('opens where lazy.nvim clones it from', function()
      assert.same(
        { 'https://github.com/ofirgall/open.nvim' },
        lazy.open_fn("'ofirgall/open.nvim'")
      )
      assert.same(
        { 'https://gitlab.com/me/mine.nvim' },
        lazy.open_fn('"me/mine.nvim"')
      )
    end)

    it('leaves a path, or a plugin it does not know, to the next', function()
      assert.is_nil(lazy.open_fn('lua/util'))
      assert.is_nil(lazy.open_fn("'lua/util.lua'"))
      assert.is_nil(lazy.open_fn('ofirgall/open.nvim'))
    end)
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

  it('registers the Jira opener with open.nvim', function()
    local set_up, registered = nil, {}
    table.insert(
      restores,
      h.stub(package.loaded, 'open', {
        setup = function(opts) set_up = opts end,
        register_opener = function(opener) table.insert(registered, opener) end,
      })
    )
    local open = spec_of('ofirgall/open.nvim')
    local opts = {
      self_defined_openers = { { name = 'jira', open_fn = function() end } },
    }
    open.config(nil, opts)
    assert.equals(opts, set_up)
    assert.same(opts.self_defined_openers, registered)
  end)

  describe('`gx`', function()
    local seen, opened, cell, notified, failure

    --- Put `line` in a buffer, the cursor on its first character, and press
    --- `gx`
    ---@param line string
    local function gx(line)
      vim.api.nvim_set_current_buf(h.buffer({ lines = { line } }))
      vim.api.nvim_win_set_cursor(0, { 1, 0 })
      for _, key in ipairs(spec_of('ofirgall/open.nvim').keys) do
        if key[1] == 'gx' then key[2]() end
      end
    end

    before_each(function()
      seen, opened, cell, notified, failure = {}, {}, nil, {}, nil
      table.insert(
        restores,
        h.stub(
          vim,
          'notify',
          function(msg, level)
            table.insert(notified, { msg = msg, level = level })
          end
        )
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'open', {
          extract_table_cell_text = function() return cell end,
          openers = {
            {
              name = 'example',
              open_fn = function(text)
                table.insert(seen, text)
                if text:find('example.com', 1, true) then return { text } end
              end,
            },
          },
        })
      )
      table.insert(
        restores,
        h.stub(vim.ui, 'open', function(path)
          table.insert(opened, path)
          return nil, failure
        end)
      )
    end)
    after_each(function() vim.cmd('silent! %bwipeout!') end)

    it('hands the word to the openers as it reads', function()
      gx('https://example.com/?t=$HOME,')
      assert.same({ 'https://example.com/?t=$HOME' }, seen)
      assert.same({ 'https://example.com/?t=$HOME' }, opened)
    end)

    it('runs no command written in backticks', function()
      -- Run, it would read as the working directory
      gx('`pwd`')
      assert.same({ '`pwd`' }, seen)
      -- Neither a URL nor a file: nothing is opened, and it says so
      assert.same({}, opened)
      assert.equals(vim.log.levels.WARN, notified[1].level)
    end)

    it('fills in no variable of a word that is no file', function()
      -- `vim.ui.open` would normalize it as a path, filling `$HOME` in
      gx('$HOME')
      assert.same({}, opened)
      assert.matches('Nothing to open', notified[1].msg)
    end)

    it('opens a file that exists as a file URI, `$` and all', function()
      local dir, cleanup = h.tmpdir()
      local file = vim.uv.fs_realpath(dir) .. '/a$HOME.txt'
      h.write(file, { '' })
      gx(file)
      cleanup()
      assert.same({ vim.uri_from_fname(file) }, opened)
    end)

    it('takes no text for a URI that the system opener would not', function()
      -- `vim.ui.open` reads `<word>:` as a scheme; before `-:` it normalizes
      gx('x-:$HOME')
      assert.same({}, opened)
      assert.matches('Nothing to open', notified[1].msg)
    end)

    it('fills in no variable of a path under the home', function()
      local dir, cleanup = h.tmpdir()
      local home = vim.uv.fs_realpath(dir)
      local restore_home = h.stub(vim.env, 'HOME', home)
      h.write(home .. '/x$USER.txt', { '' })
      gx('~/x$USER.txt')
      restore_home()
      cleanup()
      assert.same({ vim.uri_from_fname(home .. '/x$USER.txt') }, opened)
    end)

    it("opens an opener's bare host on the web", function()
      gx('www.example.com/x')
      assert.same({ 'https://www.example.com/x' }, opened)
    end)

    it('says when the system opener cannot start', function()
      failure = 'vim.ui.open: no handler found'
      gx('https://example.com/')
      assert.same({ 'https://example.com/' }, opened)
      assert.equals(vim.log.levels.ERROR, notified[1].level)
      assert.matches('no handler', notified[1].msg)
    end)

    it('tries the table cell before the word', function()
      cell = 'https://example.com/a'
      gx('word')
      assert.same({ 'https://example.com/a' }, seen)
      assert.same({ 'https://example.com/a' }, opened)
    end)
  end)
end)
