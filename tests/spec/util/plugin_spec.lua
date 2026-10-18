local h = require('helpers')

describe('util.plugin', function()
  local plugin
  before_each(function()
    h.unload('util.plugin')
    plugin = require('util.plugin')
  end)

  it('drops repeated items and keeps the first order', function()
    assert.are.same(
      { 'b', 'a', 'c' },
      plugin.dedup({ 'b', 'a', 'b', 'c', 'a' })
    )
    assert.are.same({}, plugin.dedup({}))
  end)

  it('extends a nested list, creating the tables on the way', function()
    local t = { servers = { vtsls = { filetypes = { 'ts' } } } }
    plugin.extend(t, 'servers.vtsls.filetypes', { 'vue' })
    assert.are.same({ 'ts', 'vue' }, t.servers.vtsls.filetypes)
    plugin.extend(t, 'a.b', { 1, 2 })
    assert.are.same({ 1, 2 }, t.a.b)
  end)

  it('registers the LazyFile event with lazy.nvim', function()
    plugin.lazy_file()
    local mappings = require('lazy.core.handler.event').mappings
    assert.are.same(plugin.lazy_file_events, mappings.LazyFile.event)
    assert.are.equal(mappings.LazyFile, mappings['User LazyFile'])
  end)

  describe('set_default', function()
    local bufnr
    before_each(function()
      bufnr = h.buffer()
      vim.api.nvim_set_current_buf(bufnr)
      plugin.snapshot_options()
    end)
    after_each(function() vim.cmd('silent! %bwipeout!') end)

    it('sets an option still at its global value', function()
      assert.is_true(plugin.set_default('foldmethod', 'expr'))
      assert.are.equal('expr', vim.wo.foldmethod)
    end)

    it('sets an option it set itself before', function()
      plugin.set_default('foldmethod', 'expr')
      assert.is_true(plugin.set_default('foldmethod', 'marker'))
    end)

    it('leaves an option a script outside $VIMRUNTIME set', function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/ftplugin.vim', { 'setlocal foldmethod=syntax' })
      vim.cmd.source(dir .. '/ftplugin.vim')
      assert.is_false(plugin.set_default('foldmethod', 'expr'))
      assert.are.equal('syntax', vim.wo.foldmethod)
      cleanup()
    end)

    it('leaves an option something else changed', function()
      vim.wo.foldmethod = 'syntax'
      assert.is_false(plugin.set_default('foldmethod', 'expr'))
      assert.are.equal('syntax', vim.wo.foldmethod)
    end)
  end)

  describe('lazy.nvim lookups', function()
    local restores
    before_each(function()
      restores = {
        h.stub(package.loaded, 'lazy.core.config', {
          spec = {
            plugins = {
              ['snacks.nvim'] = { dir = '/lazy/snacks.nvim' },
            },
          },
          plugins = {
            ['snacks.nvim'] = { _ = { loaded = { time = 1 } } },
            ['flash.nvim'] = { _ = {} },
          },
        }),
        h.stub(package.loaded, 'lazy.core.plugin', {
          values = function(plugin, field)
            return field == 'opts' and { dir = plugin.dir } or {}
          end,
        }),
      }
    end)
    after_each(function()
      for i = #restores, 1, -1 do
        restores[i]()
      end
    end)

    it('knows which plugins are part of the configuration', function()
      assert.is_true(plugin.has('snacks.nvim'))
      assert.is_false(plugin.has('telescope.nvim'))
    end)

    it('knows which plugins have loaded', function()
      assert.is_true(plugin.is_loaded('snacks.nvim'))
      assert.is_false(plugin.is_loaded('flash.nvim'))
      assert.is_false(plugin.is_loaded('telescope.nvim'))
    end)

    it('finds a path inside an installed plugin', function()
      assert.are.equal(
        '/lazy/snacks.nvim/lua/snacks/init.lua',
        plugin.get_plugin_path('snacks.nvim', 'lua/snacks/init.lua')
      )
      assert.is_nil(plugin.get_plugin_path('telescope.nvim'))
    end)

    it('merges the options of a plugin, empty for an unknown one', function()
      assert.are.same({ dir = '/lazy/snacks.nvim' }, plugin.opts('snacks.nvim'))
      assert.are.same({}, plugin.opts('telescope.nvim'))
    end)

    it('runs on_load right away for a loaded plugin', function()
      local seen
      plugin.on_load('snacks.nvim', function(name) seen = name end)
      assert.are.equal('snacks.nvim', seen)
    end)

    it('waits for LazyLoad of a plugin not loaded yet, once', function()
      local seen = 0
      plugin.on_load('flash.nvim', function() seen = seen + 1 end)
      vim.api.nvim_exec_autocmds('User', { pattern = 'LazyLoad', data = 'x' })
      assert.are.equal(0, seen)
      for _ = 1, 2 do
        vim.api.nvim_exec_autocmds(
          'User',
          { pattern = 'LazyLoad', data = 'flash.nvim' }
        )
      end
      assert.are.equal(1, seen)
    end)
  end)

  it('runs on_very_lazy on VeryLazy', function()
    local ran = false
    plugin.on_very_lazy(function() ran = true end)
    vim.api.nvim_exec_autocmds('User', { pattern = 'VeryLazy' })
    assert.is_true(ran)
  end)

  it('queues notifications until vim.notify is replaced', function()
    local orig = vim.notify
    local seen = {}
    plugin.lazy_notify()
    vim.notify('early')
    assert.are.same({}, seen)
    vim.notify = function(msg) table.insert(seen, msg) end
    vim.wait(1000, function() return #seen > 0 end, 10)
    vim.notify = orig
    assert.are.same({ 'early' }, seen)
  end)

  it('replays once through a wrapper of the queue itself', function()
    local orig = vim.notify
    local seen = {}
    vim.notify = function(msg) table.insert(seen, msg) end
    plugin.lazy_notify()
    vim.notify('early')
    -- A watcher that delegates to whatever `vim.notify` is, as
    -- `scripts/lib/notify-watch.lua` does after every file sourced
    local queue, calls = vim.notify, 0
    vim.notify = function(...)
      -- The queue feeding itself: stop it, rather than run out of memory
      calls = calls + 1
      assert(calls < 10, 'the replay came back through the queue')
      return queue(...)
    end
    vim.wait(1000, function() return #seen > 0 end, 10)
    vim.notify('late')
    vim.notify = orig
    assert.are.same({ 'early', 'late' }, seen)
  end)

  describe('safe_keymap_set', function()
    local set, restores
    before_each(function()
      set = {}
      restores = {
        h.stub(package.loaded, 'lazy.core.handler', {
          handlers = {
            keys = {
              have = function(_, lhs, mode) return lhs == 's' and mode == 'n' end,
            },
          },
        }),
        h.stub(_G, 'Snacks', {
          keymap = {
            set = function(modes, lhs, _, opts)
              table.insert(set, { modes = modes, lhs = lhs, opts = opts })
            end,
          },
        }),
      }
    end)
    after_each(function()
      for i = #restores, 1, -1 do
        restores[i]()
      end
    end)

    it('leaves the modes a plugin spec claims to it', function()
      plugin.safe_keymap_set({ 'n', 'x' }, 's', 'x')
      assert.are.same({ 'x' }, set[1].modes)
      plugin.safe_keymap_set('n', 's', 'x')
      assert.are.equal(1, #set)
    end)

    it('maps silently unless told otherwise', function()
      plugin.safe_keymap_set('n', 'j', 'gj')
      plugin.safe_keymap_set('n', 'k', 'gk', { silent = false })
      assert.is_true(set[1].opts.silent)
      assert.is_false(set[2].opts.silent)
    end)
  end)

  it('notifies through lazy.nvim under its own title', function()
    local lazy_util = require('lazy.core.util')
    local notified = {}
    local restores = {}
    for _, level in ipairs({ 'info', 'warn', 'error' }) do
      table.insert(
        restores,
        h.stub(
          lazy_util,
          level,
          function(msg, opts) table.insert(notified, { level, msg, opts.title }) end
        )
      )
    end
    plugin.info('a')
    plugin.warn('b', { title = 'Mine' })
    plugin.error('c')
    for _, restore in ipairs(restores) do
      restore()
    end
    assert.same({
      { 'info', 'a', 'DyNeo' },
      { 'warn', 'b', 'Mine' },
      { 'error', 'c', 'DyNeo' },
    }, notified)
  end)

  it('warns about a Mason package path that is not there', function()
    local config = require('lazy.core.config')
    local warned = {}
    local restores = {
      h.stub(config, 'headless', function() return false end),
      h.stub(plugin, 'warn', function(msg) table.insert(warned, msg) end),
    }
    local dir, cleanup = h.tmpdir()
    local mason = vim.env.MASON
    vim.env.MASON = dir
    local path = plugin.get_pkg_path('stylua', 'bin/stylua')
    assert.equals(dir .. '/packages/stylua/bin/stylua', path)
    assert.is_true(vim.wait(500, function() return #warned > 0 end))
    assert.is_truthy(warned[1]:find('**stylua**', 1, true))
    assert.is_truthy(warned[1]:find('bin/stylua', 1, true))
    -- One that is there warns nothing
    h.write(dir .. '/packages/stylua/bin/stylua', { '' })
    plugin.get_pkg_path('stylua', 'bin/stylua')
    vim.wait(100)
    assert.equals(1, #warned)
    vim.env.MASON = mason
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  it('builds the path of a Mason package without warning', function()
    local restore = h.stub(vim.env, 'MASON', '/mason')
    assert.are.equal(
      '/mason/packages/stylua/bin/stylua',
      plugin.get_pkg_path('stylua', 'bin/stylua', { warn = false })
    )
    restore()
  end)

  it('draws no status column until Snacks has loaded', function()
    local restore = h.stub(package.loaded, 'snacks', nil)
    assert.are.equal('', plugin.statuscolumn())
    restore()
  end)
end)
