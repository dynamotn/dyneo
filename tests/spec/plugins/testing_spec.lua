local h = require('helpers')

describe('plugins.executor.testing: vim-test in zellij', function()
  local restores, started

  before_each(function()
    h.globals()
    started = {}
    restores = {
      h.stub(DyNeo, 'test_strategy', 'zellij'),
      h.stub(vim.fn, 'jobstart', function(argv, opts)
        table.insert(started, { argv = argv, opts = opts })
        return 1
      end),
    }
    -- `neotest` lists vim-test as a dependency of its vim-test adapter
    local spec
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/testing.lua'))
    do
      if plugin[1] == 'nvim-neotest/neotest' then
        spec = plugin.dependencies[2].dependencies
      end
    end
    spec.config(nil, {})
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.g['test#custom_strategies'] = nil
    vim.g['test#strategy'] = nil
  end)

  it('hands the command to the shell as it is, without waiting', function()
    local cmd = 'pytest test_a.py -k "x % y" # !note'
    vim.fn.call(vim.g['test#custom_strategies'].zellij, { cmd })
    assert.are.equal(1, #started)
    local argv = started[1].argv
    assert.are.equal('zellij', argv[1])
    assert.are.equal(cmd, argv[#argv])
    assert.are.equal(vim.o.shell, argv[vim.fn.index(argv, '--') + 2])
    assert.is_true(started[1].opts.detach)
  end)
end)

describe('plugins.executor.testing: neotest', function()
  local restores, plugins, neotest, setup_opts

  ---@param name string
  ---@return table
  local function spec(name)
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/testing.lua'))
    do
      if plugin[1] == name then return plugin end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    plugins = {}
    setup_opts = nil
    restores = {
      h.stub(
        package.loaded,
        'lazy.core.config',
        { spec = { plugins = plugins }, plugins = {} }
      ),
      h.stub(package.loaded, 'neotest', {
        setup = function(opts) setup_opts = opts end,
      }),
    }
    neotest = spec('nvim-neotest/neotest')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! cclose')
  end)

  --- The diagnostic settings of neotest's namespace
  ---@return table
  local function diagnostic_config()
    return vim.diagnostic.config(nil, vim.api.nvim_create_namespace('neotest'))
  end

  it(
    'ignores vim-test for every language with an adapter of its own',
    function()
      local ignored = neotest.opts.adapters['neotest-vim-test'].ignore_filetypes
      assert.is_true(vim.list_contains(ignored, 'lua'))
      -- `sh` names vim-test among its test adapters
      assert.is_false(vim.list_contains(ignored, 'sh'))
    end
  )

  it('keeps its own virtual text on one line without tiny', function()
    neotest.config(nil, { adapters = false })
    local virtual_text = diagnostic_config().virtual_text
    assert.are.equal('table', type(virtual_text))
    assert.are.equal(
      'expected 1 got 2',
      virtual_text.format({ message = '  expected 1\n\tgot   2' })
    )
    assert.is_nil(setup_opts.consumers)
    assert.is_false(setup_opts.adapters)
  end)

  it('leaves the drawing to tiny and the results to trouble', function()
    plugins['tiny-inline-diagnostic.nvim'] = {}
    plugins['trouble.nvim'] = {}
    neotest.config(nil, {})
    assert.is_false(diagnostic_config().virtual_text)
    assert.are.equal('function', type(setup_opts.consumers.trouble))
  end)

  describe('adapters', function()
    local ran

    before_each(function()
      ran = {}
      restores[#restores + 1] =
        h.stub(package.loaded, 'dy-plain', { id = 'plain' })
      restores[#restores + 1] = h.stub(package.loaded, 'dy-setup', {
        id = 'setup',
        setup = function(config) ran.setup = config end,
      })
      restores[#restores + 1] = h.stub(package.loaded, 'dy-adapter', {
        adapter = setmetatable({ id = 'adapter' }, {
          __call = function(_, config) ran.adapter = config end,
        }),
      })
      restores[#restores + 1] = h.stub(
        package.loaded,
        'dy-callable',
        setmetatable({}, {
          __call = function(_, config)
            ran.callable = config
            return { id = 'callable' }
          end,
        })
      )
      restores[#restores + 1] =
        h.stub(package.loaded, 'dy-stubborn', { id = 'stubborn' })
    end)

    ---@param adapters table
    ---@return string[]
    local function ids(adapters)
      neotest.config(nil, { adapters = adapters })
      return vim.tbl_map(function(a) return a.id end, setup_opts.adapters)
    end

    it('sets each up the way it allows, the list first', function()
      assert.are.same(
        { 'plain', 'inline', 'adapter', 'callable', 'setup' },
        ids({
          ['dy-setup'] = { x = 1 },
          ['dy-adapter'] = { y = 2 },
          ['dy-callable'] = { z = 3 },
          ['dy-skipped'] = false,
          'dy-plain',
          { id = 'inline' },
        })
      )
      assert.are.same({ x = 1 }, ran.setup)
      assert.are.same({ y = 2 }, ran.adapter)
      assert.are.same({ z = 3 }, ran.callable)
    end)

    it('takes an adapter with nothing to set up as it is', function()
      assert.are.same({ 'stubborn' }, ids({ ['dy-stubborn'] = {} }))
      assert.are.same({ 'stubborn' }, ids({ ['dy-stubborn'] = true }))
    end)

    it('refuses to configure an adapter that cannot be', function()
      assert.error_matches(
        function() ids({ ['dy-stubborn'] = { x = 1 } }) end,
        'dy%-stubborn does not support setup'
      )
    end)
  end)

  describe('trouble consumer', function()
    local trouble, calls, client, consumer

    before_each(function()
      plugins['trouble.nvim'] = {}
      calls = {}
      trouble = {
        open = true,
        is_open = function() return trouble.open end,
        refresh = function() table.insert(calls, 'refresh') end,
        close = function() table.insert(calls, 'close') end,
      }
      restores[#restores + 1] = h.stub(package.loaded, 'trouble', trouble)
      client = {
        listeners = {},
        get_position = function(_, _, opts)
          assert.are.equal('go', opts.adapter)
          return {
            get_key = function(_, id) return id ~= 'gone' and id or nil end,
          }
        end,
      }
      neotest.config(nil, {})
      consumer = setup_opts.consumers.trouble
      consumer(client)
    end)

    ---@param results table
    ---@param partial? boolean
    local function report(results, partial)
      local ret = client.listeners.results('go', results, partial)
      vim.wait(100, function() return #calls > 0 end, 10)
      return ret
    end

    it('waits for the complete results', function()
      assert.is_nil(report({ a = { status = 'failed' } }, true))
      assert.are.same({}, calls)
    end)

    it('refreshes trouble and keeps it open on a failure', function()
      assert.are.same({}, report({ a = { status = 'failed' } }))
      assert.are.same({ 'refresh' }, calls)
    end)

    it('closes trouble once everything passes', function()
      -- A failure of a position no longer in the tree does not count
      report({ a = { status = 'passed' }, gone = { status = 'failed' } })
      assert.are.same({ 'refresh', 'close' }, calls)
    end)

    it('leaves a closed trouble alone', function()
      trouble.open = false
      report({ a = { status = 'passed' } })
      assert.are.same({}, calls)
    end)
  end)

  describe('quickfix', function()
    it('opens in trouble when it is there', function()
      plugins['trouble.nvim'] = {}
      local opened
      restores[#restores + 1] = h.stub(package.loaded, 'trouble', {
        open = function(opts) opened = opts end,
      })
      neotest.opts.quickfix.open()
      assert.are.same({ mode = 'quickfix', focus = false }, opened)
    end)

    it('opens the quickfix window otherwise', function()
      neotest.opts.quickfix.open()
      local quickfix = vim.tbl_filter(
        function(win) return vim.fn.getwininfo(win)[1].quickfix == 1 end,
        vim.api.nvim_list_wins()
      )
      assert.are.equal(1, #quickfix)
    end)
  end)

  it('debugs the nearest test through nvim-dap', function()
    local ran
    package.loaded.neotest.run = { run = function(opts) ran = opts end }
    spec('mfussenegger/nvim-dap').keys[1][2]()
    assert.are.same({ strategy = 'dap' }, ran)
  end)
end)

describe('plugins.executor.testing: crazy-coverage', function()
  local dir, cleanup, build, tagged, restore_helptags

  before_each(function()
    dir, cleanup = h.tmpdir()
    -- `:helptags` itself is Neovim's, whose nightly may break it: the spec
    -- checks that the stub is written and handed over, not the tags file
    tagged = {}
    restore_helptags = h.stub(
      vim.cmd,
      'helptags',
      function(path) table.insert(tagged, path) end
    )
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/testing.lua'))
    do
      if plugin[1] == 'mr-u0b0dy/crazy-coverage.nvim' then
        build = plugin.build
      end
    end
    vim.fn.mkdir(dir .. '/doc', 'p')
  end)
  after_each(function()
    restore_helptags()
    cleanup()
  end)

  it('lays down a vimdoc stub pointing at the Markdown', function()
    build({ dir = dir })
    local help = vim.fn.readfile(dir .. '/doc/crazy-coverage.txt')
    assert.is_true(vim.startswith(help[1], '*crazy-coverage.txt*'))
    assert.is_true(vim.list_contains(help, '\t' .. dir))
    -- The directory is handed to `helptags`
    assert.same({ dir .. '/doc' }, tagged)
  end)

  it('keeps a help file that is already there', function()
    h.write(dir .. '/doc/crazy-coverage.txt', { '*crazy-coverage.txt* mine' })
    build({ dir = dir })
    assert.are.same(
      { '*crazy-coverage.txt* mine' },
      vim.fn.readfile(dir .. '/doc/crazy-coverage.txt')
    )
  end)
end)
