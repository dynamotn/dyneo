local h = require('helpers')

describe('util.format', function()
  local format, restores

  ---@param name string
  ---@param priority number
  ---@param sources string[]
  ---@param primary? boolean
  local function formatter(name, priority, sources, primary)
    return {
      name = name,
      priority = priority,
      primary = primary,
      sources = function() return sources end,
      format = function() end,
    }
  end

  before_each(function()
    h.unload('util.format')
    format = require('util.format')
    restores = {
      h.stub(vim.g, 'autoformat', nil),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.b.autoformat = nil
  end)

  it('runs only the first primary formatter with sources', function()
    format.register(formatter('lsp', 1, { 'lua_ls' }, true))
    format.register(formatter('conform', 100, { 'stylua' }, true))
    format.register(formatter('extra', 50, { 'x' }))
    format.register(formatter('empty', 200, {}, true))

    local resolved = format.resolve(0)
    local active = {}
    for _, f in ipairs(resolved) do
      active[f.name] = f.active
    end
    assert.are.same(
      { 'empty', 'conform', 'extra', 'lsp' },
      vim.tbl_map(function(f) return f.name end, resolved)
    )
    assert.are.same(
      { empty = false, conform = true, extra = true, lsp = false },
      active
    )
  end)

  it('adds its commands and the format-on-save autocmd', function()
    format.setup()
    local commands = vim.api.nvim_get_commands({})
    assert.is_not_nil(commands.DyFormat)
    assert.is_not_nil(commands.DyFormatInfo)
    assert.equals(1, #vim.api.nvim_get_autocmds({
      group = 'dyneo_format',
      event = 'BufWritePre',
    }))
  end)

  it('formats only when enabled, unless forced', function()
    local ran = 0
    local f = formatter('one', 1, { 'x' })
    f.format = function() ran = ran + 1 end
    format.register(f)
    vim.g.autoformat = false
    format.format({ buf = 0 })
    assert.equals(0, ran)
    format.format({ buf = 0, force = true })
    assert.equals(1, ran)
  end)

  it('takes the buffer setting over the global one', function()
    assert.is_true(format.enabled())
    vim.g.autoformat = false
    assert.is_false(format.enabled())
    vim.b.autoformat = true
    assert.is_true(format.enabled())
  end)

  it('formats nothing under a held directory, even when forced', function()
    local dir, cleanup = h.tmpdir()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    local ran = 0
    local notified = {}
    restores[#restores + 1] = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notified, msg) end
    )
    format.register({
      name = 'x',
      priority = 1,
      primary = true,
      sources = function() return { 'x' } end,
      format = function() ran = ran + 1 end,
    })
    local bufnr = h.buffer({ name = dir .. '/a.lua' })
    untrusted.hold(dir)
    format.format({ buf = bufnr })
    format.format({ buf = bufnr, force = true })
    assert.are.equal(0, ran)
    assert.same({}, notified)
    untrusted.release(dir)
    format.format({ buf = bufnr })
    assert.are.equal(1, ran)
    cleanup()
  end)

  it('leaves formatexpr to Vim under a held directory', function()
    local dir, cleanup = h.tmpdir()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    restores[#restores + 1] = h.stub(
      package.loaded,
      'lazy.core.config',
      { spec = { plugins = { ['conform.nvim'] = {} } }, plugins = {} }
    )
    restores[#restores + 1] = h.stub(
      package.loaded,
      'conform',
      { formatexpr = function() return 7 end }
    )
    vim.api.nvim_set_current_buf(h.buffer({ name = dir .. '/a.lua' }))
    untrusted.hold(dir)
    assert.are.equal(1, format.formatexpr())
    untrusted.forget(dir)
    assert.are.equal(7, format.formatexpr())
    cleanup()
  end)

  it('warns when forced with no formatter to run', function()
    local notified = {}
    restores[#restores + 1] = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(notified, { msg = msg, level = level }) end
    )
    format.format({ buf = 0, force = true })
    assert.are.equal(1, #notified)
    assert.are.equal('No formatter available', notified[1].msg)
    assert.are.equal(vim.log.levels.WARN, notified[1].level)
  end)

  describe('formatexpr', function()
    local plugins
    before_each(function()
      plugins = {}
      restores[#restores + 1] = h.stub(
        package.loaded,
        'lazy.core.config',
        { spec = { plugins = plugins }, plugins = {} }
      )
    end)

    it('goes through conform when it is part of the configuration', function()
      plugins['conform.nvim'] = { dir = '/lazy/conform.nvim' }
      restores[#restores + 1] = h.stub(
        package.loaded,
        'conform',
        { formatexpr = function() return 7 end }
      )
      assert.are.equal(7, format.formatexpr())
    end)

    it('falls back to the language server', function()
      restores[#restores + 1] = h.stub(
        vim.lsp,
        'formatexpr',
        function(opts) return opts.timeout_ms end
      )
      assert.are.equal(3000, format.formatexpr())
    end)
  end)

  describe('info', function()
    local notified
    before_each(function()
      notified = {}
      restores[#restores + 1] = h.stub(
        vim,
        'notify',
        function(msg, level, opts)
          table.insert(notified, { msg = msg, level = level, opts = opts })
        end
      )
    end)

    it('lists the formatters, marking the active ones', function()
      format.register(formatter('conform', 100, { 'stylua' }, true))
      format.register(formatter('lsp', 1, { 'lua_ls' }, true))
      format.register(formatter('none', 50, {}))
      format.info(0)
      assert.are.equal(1, #notified)
      local n = notified[1]
      assert.are.equal(vim.log.levels.INFO, n.level)
      assert.are.equal('DyNeo Format (enabled)', n.opts.title)
      local lines = vim.split(n.msg, '\n')
      assert.is_true(vim.list_contains(lines, '- [x] global **enabled**'))
      assert.is_true(vim.list_contains(lines, '- [x] buffer **inherit**'))
      assert.is_true(vim.list_contains(lines, '# conform ***(active)***'))
      assert.is_true(vim.list_contains(lines, '- [x] **stylua**'))
      -- The server would format too, but conform takes the buffer first
      assert.is_true(vim.list_contains(lines, '# lsp'))
      assert.is_true(vim.list_contains(lines, '- [ ] **lua_ls**'))
      -- A formatter with no source for the buffer is left out
      assert.is_false(vim.list_contains(lines, '# none'))
    end)

    it('warns when the buffer is left unformatted', function()
      vim.g.autoformat = false
      vim.b.autoformat = false
      format.info()
      local n = notified[1]
      assert.are.equal(vim.log.levels.WARN, n.level)
      assert.are.equal('DyNeo Format (disabled)', n.opts.title)
      local lines = vim.split(n.msg, '\n')
      assert.is_true(vim.list_contains(lines, '- [ ] global **disabled**'))
      assert.is_true(vim.list_contains(lines, '- [ ] buffer **disabled**'))
      assert.is_true(
        vim.list_contains(
          lines,
          '***No formatters available for this buffer.***'
        )
      )
    end)

    it('shows a buffer enabled on its own', function()
      vim.g.autoformat = false
      vim.b.autoformat = true
      format.info()
      assert.is_true(
        vim.list_contains(
          vim.split(notified[1].msg, '\n'),
          '- [x] buffer **enabled**'
        )
      )
    end)
  end)

  describe('enable and toggle', function()
    before_each(function()
      restores[#restores + 1] = h.stub(vim, 'notify', function() end)
    end)

    it('enables globally by default, clearing the buffer setting', function()
      vim.g.autoformat = false
      vim.b.autoformat = false
      format.enable()
      assert.is_true(vim.g.autoformat)
      assert.is_nil(vim.b.autoformat)
    end)

    it('sets only the buffer when asked', function()
      vim.g.autoformat = true
      format.enable(false, true)
      assert.is_true(vim.g.autoformat)
      assert.is_false(vim.b.autoformat)
    end)

    it('toggles the current setting', function()
      format.toggle()
      assert.is_false(vim.g.autoformat)
      format.toggle(true)
      assert.is_true(vim.b.autoformat)
      assert.is_false(vim.g.autoformat)
    end)

    it('formats through the module itself', function()
      local ran = 0
      local f = formatter('one', 1, { 'x' })
      f.format = function() ran = ran + 1 end
      format.register(f)
      format({ buf = 0 })
      assert.are.equal(1, ran)
    end)
  end)

  describe('snacks toggle', function()
    local specs
    before_each(function()
      specs = {}
      restores[#restores + 1] = h.stub(_G, 'Snacks', {
        toggle = function(spec)
          table.insert(specs, spec)
          return spec
        end,
      })
      restores[#restores + 1] = h.stub(vim, 'notify', function() end)
    end)

    it('reads and sets the global setting', function()
      local toggle = format.snacks_toggle()
      assert.are.equal('Auto Format (Global)', toggle.name)
      assert.is_true(toggle.get())
      toggle.set(false)
      assert.is_false(vim.g.autoformat)
      assert.is_false(toggle.get())
    end)

    it('reads and sets the buffer setting', function()
      local toggle = format.snacks_toggle(true)
      assert.are.equal('Auto Format (Buffer)', toggle.name)
      vim.g.autoformat = false
      assert.is_false(toggle.get())
      toggle.set(true)
      assert.is_true(vim.b.autoformat)
      assert.is_true(toggle.get())
      assert.is_false(vim.g.autoformat)
    end)
  end)
end)
