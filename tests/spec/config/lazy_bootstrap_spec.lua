local h = require('helpers')

-- The lazy.nvim clone runs before anything is on screen: it has a deadline,
-- and a clone that misses it leaves nothing behind that passes for an install
describe('config.lazy bootstrap', function()
  local dir, cleanup, restores, echoed, cmds

  before_each(function()
    dir, cleanup = h.tmpdir()
    echoed, cmds = {}, {}
    restores = {
      h.stub(vim.fn, 'stdpath', function() return dir end),
      h.stub(
        vim,
        'system',
        h.system_double(function(cmd, opts)
          table.insert(cmds, { cmd = cmd, opts = opts })
          vim.fn.mkdir(cmd[#cmd], 'p')
          return { code = 124, signal = 15 }
        end)
      ),
      h.stub(vim.fn, 'getchar', function() return 0 end),
      h.stub(vim.api, 'nvim_echo', function(chunks)
        for _, chunk in ipairs(chunks) do
          table.insert(echoed, chunk[1])
        end
      end),
      h.stub(os, 'exit', function(code) error('exit ' .. code, 0) end),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  it('gives up on a clone past its deadline and says why', function()
    local ok, err = pcall(dofile, h.root .. '/lua/config/lazy.lua')
    assert.is_false(ok)
    assert.are.equal('exit 1', err)
    assert.are.equal('git', cmds[1].cmd[1])
    assert.is_number(cmds[1].opts.timeout)
    assert.truthy(table.concat(echoed):find('took longer than', 1, true))
    assert.is_nil(vim.uv.fs_stat(dir .. '/lazy/lazy.nvim'))
  end)
end)

-- Everything around `lazy.setup`: the options and leaders ahead of the
-- specs, the channel's lockfile and version policy, the colorscheme that may
-- not be there yet, and what waits for `VeryLazy`
describe('config.lazy setup', function()
  local dir, cleanup, restores, setup_opts, loaded, warned, saved

  --- Count the loads of `name` through a preload, so a stub tells when it
  --- was required
  ---@param name string
  ---@param module? table
  local function count_loads(name, module)
    loaded[name] = 0
    table.insert(restores, h.stub(package.loaded, name, nil))
    table.insert(
      restores,
      h.stub(package.preload, name, function()
        loaded[name] = loaded[name] + 1
        return module or {}
      end)
    )
  end

  before_each(function()
    h.globals()
    -- Loaded anew each time: what it records of the clipboard is read back
    h.unload('config.options')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/data/lazy/lazy.nvim', 'p')
    setup_opts, loaded, warned = nil, {}, {}
    saved = {
      ssh = vim.env.SSH_CONNECTION,
      notify = vim.notify,
      deprecate = vim.deprecate,
      clipboard = vim.o.clipboard,
      rtp = vim.o.runtimepath,
    }
    -- Not over SSH: the options then ask for the system clipboard
    vim.env.SSH_CONNECTION = nil
    local stdpath = vim.fn.stdpath
    restores = {
      h.stub(vim.fn, 'stdpath', function(what)
        if what == 'data' then return dir .. '/data' end
        if what == 'config' then return dir .. '/config' end
        return stdpath(what)
      end),
      h.stub(vim.fn, 'argc', function() return 0 end),
      h.stub(
        require('lazy.core.util'),
        'warn',
        function(msg) table.insert(warned, msg) end
      ),
      h.stub(package.loaded, 'lazy', {
        setup = function(opts) setup_opts = opts end,
      }),
      h.stub(package.loaded, 'lazy.health', { valid = {} }),
      h.stub(package.loaded, 'tools.lazy-quarantine', {
        setup = function() loaded.quarantine = true end,
        bootstrap = function() end,
      }),
      h.stub(package.loaded, 'util.project_rtp', {
        startup_path = function() return dir .. '/.nvim' end,
        setup = function() loaded.project_rtp = true end,
      }),
      h.stub(package.loaded, 'util.root', {
        setup = function() loaded.root = true end,
        get = function() return vim.fn.getcwd() end,
      }),
      h.stub(package.loaded, 'util.format', {
        setup = function() loaded.format = true end,
      }),
      h.stub(package.loaded, 'util.rename', {
        setup = function() loaded.rename = true end,
      }),
    }
    count_loads('config.autocmds')
    count_loads('config.keymaps')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.env.SSH_CONNECTION = saved.ssh
    vim.notify = saved.notify
    vim.deprecate = saved.deprecate
    vim.o.clipboard = saved.clipboard
    vim.o.runtimepath = saved.rtp
    pcall(vim.api.nvim_clear_autocmds, { event = 'User', pattern = 'VeryLazy' })
    cleanup()
  end)

  local function load() dofile(h.root .. '/lua/config/lazy.lua') end

  local function very_lazy()
    vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
  end

  it('sets lazy.nvim up for the latest channel', function()
    DyNeo.plugin_channel = 'latest'
    load()
    assert.is_not_nil(setup_opts)
    assert.is_false(setup_opts.defaults.version)
    assert.is_true(setup_opts.defaults.lazy)
    assert.are.equal(dir .. '/config/lazy-lock.json', setup_opts.lockfile)
    assert.is_false(setup_opts.checker.notify)
    assert.are.same({ 'catppuccin' }, setup_opts.install.colorscheme)
    assert.are.same({ dir .. '/.nvim' }, setup_opts.performance.rtp.paths)
    assert.are.equal(DyNeo.dev_plugins_path, setup_opts.dev.path)
    assert.is_true(setup_opts.dev.fallback)
    assert.is_false(setup_opts.rocks.enabled)
    -- No stale release pins on `latest`
    assert.are.same({}, setup_opts.spec[#setup_opts.spec])
    local imports = {}
    for _, spec in ipairs(setup_opts.spec) do
      if spec.import then table.insert(imports, spec.import) end
    end
    assert.is_true(vim.list_contains(imports, 'plugins.lang'))
    assert.are.same({ 'folke/lazy.nvim', version = '*' }, setup_opts.spec[1])
    assert.is_true(loaded.quarantine)
    assert.is_true(loaded.project_rtp)
  end)

  it('keeps stale releases on their branch for the stable channel', function()
    DyNeo.plugin_channel = 'stable'
    load()
    assert.are.equal('*', setup_opts.defaults.version)
    assert.are.equal(
      dir .. '/config/lazy-lock.stable.json',
      setup_opts.lockfile
    )
    assert.is_true(setup_opts.checker.notify)
    local stale = setup_opts.spec[#setup_opts.spec]
    assert.is_true(#stale > 0)
    for _, spec in ipairs(stale) do
      assert.is_true(spec.optional, spec[1])
      assert.is_false(spec.version, spec[1])
    end
  end)

  it('falls back to a built-in colorscheme and says so', function()
    load()
    assert.are.equal('habamax', vim.g.colors_name)
    assert.is_truthy(warned[1]:find('`catppuccin` not found', 1, true))
  end)

  it('inspects a plugin from the Lazy UI with dd', function()
    local inspected
    local restore = h.stub(_G, 'dd', function(plugin) inspected = plugin end)
    load()
    setup_opts.ui.custom_keys['<localleader>d']({ name = 'x' })
    restore()
    assert.are.same({ name = 'x' }, inspected)
  end)

  it('silences deprecation warnings as the options ask', function()
    load()
    assert.are_not.equal(saved.deprecate, vim.deprecate)
    assert.is_nil(vim.deprecate('old', 'new', '1.0'))
  end)

  it('gives the clipboard and the helpers back on VeryLazy', function()
    load()
    assert.are.equal('', vim.o.clipboard)
    assert.are.equal(0, loaded['config.autocmds'])
    assert.are.equal(0, loaded['config.keymaps'])
    very_lazy()
    assert.are.equal('unnamedplus', vim.o.clipboard)
    assert.is_true(loaded.format)
    assert.is_true(loaded.root)
    assert.is_true(loaded.rename)
    assert.are.equal(1, loaded['config.autocmds'])
    assert.are.equal(1, loaded['config.keymaps'])
    assert.are.same({ 'vscode' }, require('lazy.health').valid)
  end)

  it('loads the autocmds at once when files were given', function()
    restores[2]()
    restores[2] = h.stub(vim.fn, 'argc', function() return 1 end)
    load()
    assert.are.equal(1, loaded['config.autocmds'])
    assert.are.equal(0, loaded['config.keymaps'])
    very_lazy()
    assert.are.equal(1, loaded['config.autocmds'])
    assert.are.equal(1, loaded['config.keymaps'])
  end)

  it('walks a fresh clone back behind the quarantine', function()
    vim.fn.delete(dir .. '/data/lazy', 'rf')
    local cloned, walked_back
    table.insert(
      restores,
      h.stub(
        vim,
        'system',
        h.system_double(function(cmd)
          cloned = cmd[#cmd]
          vim.fn.mkdir(cloned, 'p')
          return { code = 0 }
        end)
      )
    )
    package.loaded['tools.lazy-quarantine'].bootstrap = function(path)
      walked_back = path
    end
    load()
    assert.are.equal(dir .. '/data/lazy/lazy.nvim', cloned)
    assert.are.equal(cloned, walked_back)
    assert.is_not_nil(setup_opts)
  end)
end)
