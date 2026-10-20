local h = require('helpers')

describe('plugins.executor.linting', function()
  local spec, lint, linted, restores

  before_each(function()
    h.globals()
    linted = {}
    lint = {
      linters = {
        -- On every machine: what runs it is all the filter asks
        present = { cmd = 'sh' },
        absent = { cmd = 'dy-no-such-linter' },
        declined = { cmd = 'sh', condition = function() return false end },
        compiler = {},
      },
      linters_by_ft = {},
      try_lint = function(names) table.insert(linted, names) end,
      _resolve_linter_by_ft = function(ft) return lint.linters_by_ft[ft] or {} end,
    }
    restores = {
      h.stub(package.loaded, 'lint', lint),
      -- Reads nvim-lint's own parsers, which the stub has none of
      h.stub(package.loaded, 'util.lint_code', { setup = function() end }),
    }
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/linting.lua'))
    do
      if plugin[1] == 'mfussenegger/nvim-lint' then spec = plugin end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  --- What reached `try_lint` from the debounced runner: vale runs from a
  --- `BufWritePost` of its own, where this machine has it and a config
  local function runs()
    return vim.tbl_filter(
      function(names) return not vim.list_contains(names, 'vale') end,
      linted
    )
  end

  --- Set nvim-lint up, open a buffer of a filetype naming every linter, run
  --- `before`, then write it
  ---@param before? fun()
  local function lint_on_write(before)
    local opts = spec.opts(nil, {})
    opts.events = { 'BufWritePost' }
    opts.linters_by_ft =
      { dytext = { 'present', 'absent', 'declined', 'compiler' } }
    spec.config(nil, opts)
    local bufnr = h.buffer({ name = vim.fn.tempname() .. '.txt' })
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'dytext'
    if before then before() end
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    vim.wait(500, function() return #runs() > 0 end, 10)
  end

  it('runs only the linters that can run on the buffer', function()
    lint_on_write()
    assert.same({ { 'present' } }, runs())
  end)

  it('lints a held directory only once it is let go', function()
    local dir, cleanup = h.tmpdir()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    local opts = spec.opts(nil, {})
    opts.events = { 'BufWritePost' }
    opts.linters_by_ft = { dytext = { 'present' } }
    spec.config(nil, opts)
    local bufnr = h.buffer({ name = dir .. '/a.txt', filetype = 'dytext' })
    local other =
      h.buffer({ name = dir .. '-other/a.txt', filetype = 'dytext' })
    untrusted.hold(dir)
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    assert.is_false(vim.wait(300, function() return #runs() > 0 end, 10))
    -- Its sibling is nothing held
    vim.api.nvim_set_current_buf(other)
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = other })
    assert.is_true(vim.wait(500, function() return #runs() > 0 end, 10))
    linted = {}
    -- Let go: the buffers under it are linted once, whichever is current
    untrusted.release(dir)
    assert.same({ { 'present' } }, runs())
    cleanup()
  end)

  it('lints nothing while the editor quits, again once it stays', function()
    lint_on_write(function() vim.api.nvim_exec_autocmds('QuitPre', {}) end)
    assert.same({}, runs())
    -- A window closed, not the editor: back to waiting for input
    vim.api.nvim_exec_autocmds('SafeState', {})
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = 0 })
    assert.is_true(vim.wait(500, function() return #runs() > 0 end, 10))
  end)
end)

describe('plugins.executor.linting: rebuilding and vale', function()
  local spec, lint, linted, restores, plugins, dir, cleanup

  before_each(function()
    h.globals()
    linted = {}
    plugins = {}
    dir, cleanup = h.tmpdir()
    lint = {
      linters = { present = { cmd = 'sh' } },
      linters_by_ft = {},
      try_lint = function(names) table.insert(linted, names) end,
      _resolve_linter_by_ft = function(ft) return lint.linters_by_ft[ft] or {} end,
    }
    restores = {
      h.stub(package.loaded, 'lint', lint),
      h.stub(package.loaded, 'util.lint_code', { setup = function() end }),
      h.stub(
        package.loaded,
        'lazy.core.config',
        { spec = { plugins = {} }, plugins = plugins }
      ),
      h.stub(vim.env, 'VALE_CONFIG_PATH', nil),
    }
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/linting.lua'))
    do
      if plugin[1] == 'mfussenegger/nvim-lint' then spec = plugin end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('rebuilds the lists once Mason installs a linter', function()
    local handlers = {}
    plugins['mason.nvim'] = { _ = { loaded = {} } }
    restores[#restores + 1] = h.stub(package.loaded, 'mason-registry', {
      on = function(_, event, handler) handlers[event] = handler end,
    })
    local available = false
    restores[#restores + 1] = h.stub(
      require('util.languages'),
      'is_available',
      function() return available end
    )
    local opts = spec.opts(nil, {})
    -- Nothing is installed yet, so `sh` has no linter
    assert.are.same({}, opts.linters_by_ft.sh)
    lint.linters_by_ft = opts.linters_by_ft
    available = true
    handlers['package:install:success']()
    assert.is_true(
      vim.wait(500, function() return #lint.linters_by_ft.sh > 0 end, 10)
    )
    assert.is_true(vim.list_contains(lint.linters_by_ft.sh, 'dyshellint'))
  end)

  describe('vale', function()
    local executable

    --- Write a buffer named `name`, and wait for vale to be asked for
    ---@param name string
    ---@return boolean asked
    local function write(name)
      local bufnr = h.buffer({ name = name })
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
      return vim.wait(500, function() return #linted > 0 end, 10)
    end

    before_each(function()
      executable = { vale = 1 }
      restores[#restores + 1] = h.stub(
        vim.fn,
        'executable',
        function(name) return executable[name] or 0 end
      )
      spec.opts(nil, {})
    end)

    it('runs on a write when its config is above the file', function()
      h.write(dir .. '/.vale.ini', { 'StylesPath = styles' })
      assert.is_true(write(dir .. '/docs/a.md'))
      assert.are.same({ { 'vale' } }, linted)
    end)

    it('runs when the environment names a config', function()
      h.write(dir .. '/vale.ini', { 'StylesPath = styles' })
      vim.env.VALE_CONFIG_PATH = dir .. '/vale.ini'
      assert.is_true(write(dir .. '/a.md'))
    end)

    it('stays quiet without a config', function()
      vim.env.VALE_CONFIG_PATH = dir .. '/missing.ini'
      assert.is_false(write(dir .. '/a.md'))
    end)

    it('stays quiet without the binary', function()
      executable.vale = nil
      h.write(dir .. '/.vale.ini', { 'StylesPath = styles' })
      assert.is_false(write(dir .. '/a.md'))
    end)

    it('stays quiet for a held directory', function()
      h.write(dir .. '/.vale.ini', { 'StylesPath = styles' })
      h.unload('util.untrusted')
      local untrusted = require('util.untrusted')
      untrusted.hold(dir)
      assert.is_false(write(dir .. '/docs/a.md'))
      untrusted.forget(dir)
      assert.is_true(write(dir .. '/docs/b.md'))
    end)

    it('stays quiet for a buffer without a file', function()
      h.write(dir .. '/.vale.ini', { 'StylesPath = styles' })
      local bufnr = h.buffer({})
      vim.api.nvim_set_current_buf(bufnr)
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
      assert.is_false(vim.wait(300, function() return #linted > 0 end, 10))
    end)
  end)
end)

describe('plugins.executor.linting: configuring nvim-lint', function()
  local spec, lint, linted, restores, notified

  before_each(function()
    h.globals()
    linted, notified = {}, {}
    lint = {
      linters = {
        present = { cmd = 'sh', args = { '--lint' } },
        fallback = { cmd = 'sh' },
      },
      linters_by_ft = {},
      try_lint = function(names) table.insert(linted, names) end,
      _resolve_linter_by_ft = function(ft) return lint.linters_by_ft[ft] or {} end,
    }
    restores = {
      h.stub(package.loaded, 'lint', lint),
      h.stub(package.loaded, 'util.lint_code', { setup = function() end }),
      h.stub(
        vim,
        'notify',
        function(msg, level, opts)
          table.insert(notified, { msg = msg, level = level, opts = opts })
        end
      ),
    }
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/linting.lua'))
    do
      if plugin[1] == 'mfussenegger/nvim-lint' then spec = plugin end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  ---@param by_ft table<string, string[]>
  ---@param linters table<string, table>
  local function setup(by_ft, linters)
    local opts = spec.opts(nil, {})
    opts.events = { 'BufWritePost' }
    opts.linters_by_ft = by_ft
    opts.linters = linters
    spec.config(nil, opts)
  end

  --- Write a buffer of `ft`, and wait for the linters to run
  ---@param ft string
  local function write(ft)
    local bufnr = h.buffer({ name = vim.fn.tempname() .. '.txt' })
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = ft
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    vim.wait(500, function() return #linted > 0 end, 10)
  end

  it('merges the options of a linter nvim-lint ships', function()
    setup({}, {
      present = { prepend_args = { '--strict' }, ignore_exitcode = true },
      mine = { cmd = 'sh', args = { '-c', 'true' } },
    })
    assert.are.same({ '--strict', '--lint' }, lint.linters.present.args)
    assert.is_true(lint.linters.present.ignore_exitcode)
    assert.are.equal('sh', lint.linters.present.cmd)
    assert.are.same({ '-c', 'true' }, lint.linters.mine.args)
  end)

  it('falls back to the `_` linters for a filetype with none', function()
    setup({ _ = { 'fallback' } }, {})
    write('dytext')
    assert.are.same({ { 'fallback' } }, linted)
  end)

  it('says which linter is missing, and runs the rest', function()
    setup({ dytext = { 'nowhere', 'present' } }, {})
    write('dytext')
    assert.are.same({ { 'present' } }, linted)
    assert.are.equal(1, #notified)
    assert.are.equal('Linter not found: nowhere', notified[1].msg)
    assert.are.equal(vim.log.levels.WARN, notified[1].level)
    assert.are.equal('DyNeo Lint', notified[1].opts.title)
  end)

  it('lints no special buffer', function()
    setup({ _ = { 'fallback' } }, {})
    local bufnr = h.buffer({})
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].buftype = 'nofile'
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    assert.is_false(vim.wait(300, function() return #linted > 0 end, 10))
  end)
end)

describe('plugins.executor.linting: installing linters', function()
  local spec, restores, installed, handlers

  before_each(function()
    h.globals()
    installed, handlers = {}, {}
    restores = {
      h.stub(package.loaded, 'config.languages', {
        sh = {
          filetypes = { 'sh', 'bash' },
          linters = {
            'shellcheck',
            { 'zsh', mason = { package = 'zsh-bin' } },
            { 'system', mason = { enabled = false } },
          },
        },
        lua = { filetypes = { 'lua' }, linters = { 'selene' } },
        ['*'] = { filetypes = { '*' }, linters = { 'typos' } },
        ['_'] = { filetypes = { '_' }, linters = { { 'cspell' } } },
      }),
      -- `util.languages` read the languages when it loaded
      function() h.unload('util.languages') end,
      h.stub(package.loaded, 'util.lazy_install', {
        on_filetype = function(filetypes, handler)
          table.insert(handlers, { filetypes = filetypes, handler = handler })
        end,
        install_once = function(package) table.insert(installed, package) end,
      }),
    }
    h.unload('util.languages')
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/linting.lua'))
    do
      if plugin[1] == 'mason-org/mason.nvim' then spec = plugin end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('installs the common and bundled linters up front', function()
    DyNeo.bundle_languages = { 'lua' }
    DyNeo.enabled_languages = { 'sh' }
    local opts = { ensure_installed = {} }
    spec.opts(nil, opts)
    assert.are.same({ 'typos', 'cspell', 'selene' }, opts.ensure_installed)
  end)

  it('installs the linters of a language with its first buffer', function()
    DyNeo.enabled_languages = { 'sh' }
    spec.opts(nil, { ensure_installed = {} })
    -- One handler per Mason-installed linter, none for the system one
    assert.are.equal(2, #handlers)
    for _, handler in ipairs(handlers) do
      handler.handler()
    end
    assert.are.same({ 'shellcheck', 'zsh-bin' }, installed)
    assert.are.same({ 'sh', 'bash' }, handlers[1].filetypes)
  end)
end)
