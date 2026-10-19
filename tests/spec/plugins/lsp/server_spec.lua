local h = require('helpers')

describe('plugins.lsp.server', function()
  local spec, restores, dir, cleanup
  -- What the stubs record
  local calls, base, mason_packages, installed, enabled_of, held

  --- Record a call under `name`
  ---@param name string
  ---@return fun(...)
  local function record(name)
    return function(...)
      calls[name] = calls[name] or {}
      table.insert(calls[name], { ... })
    end
  end

  --- The nvim-lspconfig spec of the file
  ---@return table
  local function load()
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/lsp/server.lua')) do
      if plugin[1] == 'neovim/nvim-lspconfig' then return plugin end
    end
    error('no nvim-lspconfig spec')
  end

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    calls, installed, held = {}, {}, {}
    enabled_of = { sonarlint = true, bashls = true }
    -- What `lsp/<server>.lua` would ship, read by `vim.lsp.config[server]`
    base = {
      sonarlint = { root_markers = { 'sonar-project.properties' } },
      termuxls = {
        root_dir = function(_, on_dir) on_dir('/termux') end,
      },
      yamlls = { filetypes = { 'yaml', 'json' } },
      helm_ls = { filetypes = { 'helm' } },
      lua_ls = { filetypes = { 'lua' } },
      bashls = {},
    }
    mason_packages = {
      lua_ls = 'lua-language-server',
      stylua = 'stylua',
      yamlls = 'yaml-language-server',
      helm_ls = 'helm-ls',
      gopls = 'gopls',
      golangci_lint_ls = 'golangci-lint-langserver',
      bashls = 'bash-language-server',
    }
    local languages = {
      ['*'] = {
        filetypes = { '*' },
        lsp_servers = {
          { 'sonarlint', enabled = function() return enabled_of.sonarlint end },
          'copilot',
        },
      },
      go = {
        filetypes = { 'go' },
        lsp_servers = { 'gopls', 'golangci_lint_ls' },
      },
      lua = { filetypes = { 'lua' }, lsp_servers = { 'lua_ls', 'stylua' } },
      sh = {
        filetypes = { 'sh' },
        lsp_servers = {
          { 'bashls', enabled = function() return enabled_of.bashls end },
          { 'termuxls', enabled = function() return true end },
        },
      },
      yaml = {
        filetypes = { 'yaml', 'yaml.helm-values' },
        lsp_servers = {
          { 'helm_ls', filetypes = { 'yaml.helm-values' } },
          'yamlls',
        },
      },
    }
    restores = {
      h.stub(package.loaded, 'config.languages', languages),
      h.stub(_G, 'Snacks', {
        util = { lsp = { on = record('lsp_on') } },
        keymap = { set = record('keymap') },
        picker = { lsp_config = record('lsp_config') },
        words = {
          jump = record('jump'),
          is_enabled = function() return true end,
        },
      }),
      h.stub(package.loaded, 'codesettings', {
        with_local_settings = record('local_settings'),
      }),
      h.stub(package.loaded, 'mason-lspconfig', {
        get_mappings = function()
          return { lspconfig_to_package = mason_packages }
        end,
        setup = record('mason_setup'),
      }),
      h.stub(package.loaded, 'mason-registry', {
        is_installed = function(package) return installed[package] == true end,
      }),
      h.stub(package.loaded, 'util.lazy_install', {
        on_filetype = record('on_filetype'),
        install_once = record('install_once'),
      }),
      h.stub(package.loaded, 'tools.workspace_diagnostics', {
        run = record('workspace_diagnostics'),
      }),
      h.stub(package.loaded, 'tiny-inline-diagnostic', nil),
      h.stub(package.loaded, 'util.untrusted', {
        held = function(bufnr) return held[bufnr] == true end,
      }),
      h.stub(vim.lsp, 'enable', record('enable')),
      h.stub(
        vim.lsp,
        'config',
        setmetatable({}, {
          __call = function(_, name, config)
            calls.config = calls.config or {}
            calls.config[name] = config
          end,
          __index = function(_, name) return base[name] end,
        })
      ),
      h.stub(vim.lsp.inlay_hint, 'enable', record('inlay_hint')),
      h.stub(vim.diagnostic, 'config', record('diagnostic')),
    }
    -- `util.languages` reads the languages once, as it loads
    h.unload('util.languages', 'util.format')
    table.insert(
      restores,
      function() h.unload('util.languages', 'util.format') end
    )
    DyNeo.bundle_languages = { 'lua' }
    DyNeo.enabled_languages = { 'go', 'lua', 'sh', 'yaml' }
    spec = load()
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- The key of `lhs` among those of `*`
  ---@param opts table
  ---@param lhs string
  ---@return table
  local function key_of(opts, lhs)
    for _, key in ipairs(opts.servers['*'].keys) do
      if key[1] == lhs then return key end
    end
    error('no key ' .. lhs)
  end

  --- The handlers `util.lazy_install` was given, by the filetypes they run
  --- on; one call runs every handler of those filetypes
  ---@return table<string, fun(args: table)>
  local function handlers_by_filetypes()
    local by_key = {}
    for _, call in ipairs(calls.on_filetype) do
      local key = table.concat(call[1], ',')
      by_key[key] = by_key[key] or {}
      table.insert(by_key[key], call[2])
    end
    local handlers = {}
    for key, list in pairs(by_key) do
      handlers[key] = function(args)
        for _, handler in ipairs(list) do
          handler(args)
        end
      end
    end
    return handlers
  end

  --- Run `config` with `opts` and wait for the mason-lspconfig setup it
  --- schedules
  ---@param opts table
  ---@return table mason What mason-lspconfig was set up with
  local function configure(opts)
    spec.config(nil, opts)
    assert.is_nil(calls.mason_setup)
    vim.wait(500, function() return calls.mason_setup ~= nil end)
    assert.is_not_nil(calls.mason_setup)
    return calls.mason_setup[1][1]
  end

  it('sets mason-lspconfig up from here, not on its own', function()
    for _, dependency in ipairs(spec.dependencies) do
      if dependency[1] == 'mason-org/mason-lspconfig.nvim' then
        assert.is_nil(dependency.config())
      end
    end
  end)

  it('runs the workspace diagnostics from a key', function()
    assert.are.equal('<leader>xw', spec.keys[1][1])
    spec.keys[1][2]()
    assert.are.equal(1, #calls.workspace_diagnostics)
  end)

  describe('opts', function()
    it('puts the default keys ahead of those added before', function()
      local mine = { 'gx', function() end, desc = 'Mine' }
      local opts = spec.opts(nil, { servers = { ['*'] = { keys = { mine } } } })
      local keys = opts.servers['*'].keys
      assert.are.equal('<leader>cl', keys[1][1])
      assert.are.equal(mine, keys[#keys])
      assert.same({ enabled = false }, opts.servers.stylua)
      assert.is_true(opts.diagnostics.underline)
    end)

    it('reads the project settings into every server', function()
      local opts = spec.opts(nil, {})
      local config = { name = 'lua_ls' }
      opts.servers['*'].before_init(nil, config)
      assert.same({ { 'lua_ls', config } }, calls.local_settings)
    end)

    it('draws the diagnostic text itself without tiny-inline', function()
      local opts = spec.opts(nil, {})
      assert.are.equal('●', opts.diagnostics.virtual_text.prefix)
      local restore = h.stub(
        require('util.plugin'),
        'has',
        function(name) return name == 'tiny-inline-diagnostic.nvim' end
      )
      opts = load().opts(nil, {})
      restore()
      assert.is_false(opts.diagnostics.virtual_text)
    end)

    it('maps the LSP actions of the buffer', function()
      local opts = spec.opts(nil, {})
      key_of(opts, '<leader>cl')[2]()
      assert.are.equal(1, #calls.lsp_config)
      -- Hover and signature help with no server attached say so quietly
      local restore = h.stub(vim, 'notify', function() end)
      key_of(opts, 'K')[2]()
      key_of(opts, 'gK')[2]()
      key_of(opts, '<leader>cC')[2]()
      restore()
      key_of(opts, ']]')[2]()
      key_of(opts, '[[')[2]()
      key_of(opts, '<a-n>')[2]()
      key_of(opts, '<a-p>')[2]()
      assert.same({ { 1 }, { -1 }, { 1, true }, { -1, true } }, calls.jump)
      assert.is_true(key_of(opts, ']]').enabled())
      -- With no client there is nothing to organize
      assert.is_false(key_of(opts, '<leader>co').enabled(0))
    end)

    it('offers Organize Imports where a client has it', function()
      local opts = spec.opts(nil, {})
      local restore = h.stub(vim.lsp, 'get_clients', function()
        return {
          {
            server_capabilities = {
              codeActionProvider = {
                codeActionKinds = { 'source.organizeImports' },
              },
            },
            dynamic_capabilities = { get = function() return {} end },
          },
        }
      end)
      local ok, offered = pcall(key_of(opts, '<leader>co').enabled, 0)
      restore()
      assert.is_true(ok, offered)
      assert.is_true(offered)
    end)
  end)

  describe('config', function()
    local opts
    before_each(function()
      opts = spec.opts(nil, {
        servers = {
          lua_ls = { settings = { Lua = {} } },
          yamlls = {},
          helm_ls = true,
          copilot = { enabled = false },
          golangci_lint_ls = {},
          bashls = { filetypes = { 'bash' } },
        },
        setup = {
          gopls = function(server, server_opts)
            calls.setup = { server, server_opts }
            return true
          end,
        },
      })
    end)

    it('registers the LSP formatter', function()
      configure(opts)
      local names = vim.tbl_map(
        function(formatter) return formatter.name end,
        require('util.format').formatters
      )
      assert.same({ 'LSP' }, names)
    end)

    it('maps `*` first, so a server key for the same lhs wins', function()
      opts.servers.lua_ls.keys = { { 'gd', function() end, desc = 'Lua' } }
      configure(opts)
      local lhs = vim.tbl_map(function(call) return call[2] end, calls.keymap)
      assert.are.equal('gd', lhs[#lhs])
      assert.are.equal('lua_ls', calls.keymap[#calls.keymap][4].lsp.name)
      -- The first `gd` is that of `*`, limited to servers with definitions
      for _, call in ipairs(calls.keymap) do
        if call[2] == 'gd' then
          assert.same({ method = 'textDocument/definition' }, call[4].lsp)
          break
        end
      end
    end)

    it('turns inlay hints on for a file buffer, not an excluded one', function()
      configure(opts)
      assert.are.equal('textDocument/inlayHint', calls.lsp_on[1][1].method)
      local on_attach = calls.lsp_on[1][2]
      local lua = h.buffer({ filetype = 'lua' })
      local vue = h.buffer({ filetype = 'vue' })
      local scratch = h.buffer({ filetype = 'lua' })
      vim.bo[scratch].buftype = 'nofile'
      local gone = h.buffer({})
      vim.api.nvim_buf_delete(gone, { force = true })
      on_attach(lua)
      on_attach(vue)
      on_attach(scratch)
      on_attach(gone)
      assert.same({ { true, { bufnr = lua } } }, calls.inlay_hint)
      assert.is_nil(calls.lsp_on[2])
    end)

    it('leaves inlay hints and code lenses off when asked', function()
      opts.inlay_hints.enabled = false
      opts.codelens.enabled = true
      configure(opts)
      assert.are.equal(1, #calls.lsp_on)
      assert.are.equal('textDocument/codeLens', calls.lsp_on[1][1].method)
      assert.are.equal(require('util.lsp').codelens.enable, calls.lsp_on[1][2])
    end)

    it('draws the diagnostic prefix from the icons', function()
      opts.diagnostics.virtual_text = { prefix = 'icons' }
      configure(opts)
      local prefix = calls.diagnostic[1][1].virtual_text.prefix
      local icons = require('config.defaults').icons.diagnostics
      assert.are.equal(
        icons.Error,
        prefix({ severity = vim.diagnostic.severity.ERROR })
      )
      assert.are.equal('●', prefix({ severity = 99 }))
    end)

    it('lays extra capabilities under every server', function()
      opts.capabilities = { textDocument = { foldingRange = {} } }
      configure(opts)
      local star = calls.config['*']
      assert.same({}, star.capabilities.textDocument.foldingRange)
      assert.is_true(star.capabilities.workspace.fileOperations.didRename)
    end)

    it('tells mason-lspconfig what to install and what to leave', function()
      local mason = configure(opts)
      assert.same({ 'lua_ls', 'stylua' }, mason.ensure_installed)
      local excluded = mason.automatic_enable.exclude
      table.sort(excluded)
      assert.same({ 'copilot', 'gopls', 'stylua' }, excluded)
      -- Handed the server widened to its filetypes
      assert.same({ 'gopls', { filetypes = { 'go' } } }, calls.setup)
      assert.is_nil(calls.config.gopls)
      assert.is_nil(calls.config.copilot)
      assert.is_nil(calls.config.stylua)
    end)

    it('turns a server off with `false`', function()
      local off = spec.opts(nil, { servers = { termuxls = false } })
      local mason = configure(off)
      assert.is_true(
        vim.list_contains(mason.automatic_enable.exclude, 'termuxls')
      )
      assert.is_nil(calls.config.termuxls)
      for _, call in ipairs(calls.enable) do
        assert.are_not.equal('termuxls', call[1])
      end
    end)

    it('enables itself a server Mason has no package for', function()
      configure(opts)
      local enabled = vim.tbl_map(
        function(call) return call[1] end,
        calls.enable
      )
      table.sort(enabled)
      assert.same({ 'sonarlint', 'termuxls' }, enabled)
    end)

    it('widens a server to every filetype that declares it', function()
      configure(opts)
      assert.same(
        { 'yaml', 'json', 'yaml.helm-values' },
        calls.config.yamlls.filetypes
      )
      -- The plugin spec's own filetypes come first
      assert.same({ 'bash', 'sh' }, calls.config.bashls.filetypes)
      -- A dialect's server is kept to that dialect
      assert.same({ 'yaml.helm-values' }, calls.config.helm_ls.filetypes)
      assert.same({ 'lua' }, calls.config.lua_ls.filetypes)
      assert.same({ Lua = {} }, calls.config.lua_ls.settings)
    end)

    describe('root_dir', function()
      before_each(function()
        -- What `lsp/<server>.lua` ships, read from the runtimepath only once a
        -- buffer asks: resolving `vim.lsp.config[server]` up front would
        -- search the runtimepath for every server
        h.write(dir .. '/lsp/sonarlint.lua', {
          "return { root_markers = { 'sonar-project.properties' } }",
        })
        h.write(dir .. '/lsp/lua_ls.lua', {
          "return { root_markers = { '.luarc.json' } }",
        })
        h.write(dir .. '/lsp/termuxls.lua', {
          "return { root_dir = function(_, on_dir) on_dir('/termux') end }",
        })
        vim.opt.runtimepath:prepend(dir)
        h.write(dir .. '/proj/sonar-project.properties')
        h.write(dir .. '/proj/.luarc.json')
        h.write(dir .. '/proj/a.py')
        h.write(dir .. '/other/b.py')
      end)
      after_each(function() vim.opt.runtimepath:remove(dir) end)

      local roots
      local function on_dir(path) table.insert(roots, path or false) end

      it('lets a conditional server decide per buffer', function()
        configure(opts)
        roots = {}
        local inside = h.buffer({ name = dir .. '/proj/a.py' })
        local outside = h.buffer({ name = dir .. '/other/b.py' })
        local root_dir = calls.config.sonarlint.root_dir
        root_dir(inside, on_dir)
        root_dir(outside, on_dir)
        enabled_of.sonarlint = false
        root_dir(inside, on_dir)
        assert.same({ dir .. '/proj', false }, roots)
        -- A server with a `root_dir` of its own keeps it
        calls.config.termuxls.root_dir(inside, on_dir)
        assert.are.equal('/termux', roots[3])
      end)

      it('holds every server off a held buffer', function()
        configure(opts)
        roots = {}
        local inside = h.buffer({ name = dir .. '/proj/a.py' })
        -- Not only the conditional servers
        local root_dir = calls.config.lua_ls.root_dir
        assert.is_function(root_dir)
        root_dir(inside, on_dir)
        assert.same({ dir .. '/proj' }, roots)
        held[inside] = true
        root_dir(inside, on_dir)
        calls.config.sonarlint.root_dir(inside, on_dir)
        calls.config.termuxls.root_dir(inside, on_dir)
        assert.same({ dir .. '/proj' }, roots)
        -- Let go, it attaches again
        held[inside] = nil
        root_dir(inside, on_dir)
        assert.same({ dir .. '/proj', dir .. '/proj' }, roots)
      end)

      it('keeps the condition a later language leaves out', function()
        -- `bashls` is conditional for `sh` only; a language naming it
        -- plainly after that must not drop the condition
        package.loaded['config.languages'].zsh = {
          filetypes = { 'zsh' },
          lsp_servers = { 'bashls' },
        }
        h.unload('util.languages')
        configure(opts)
        roots = {}
        local inside = h.buffer({ name = dir .. '/proj/a.py' })
        enabled_of.bashls = false
        calls.config.bashls.root_dir(inside, on_dir)
        assert.same({}, roots)
        package.loaded['config.languages'].zsh = nil
      end)
    end)

    it('installs a server on the first buffer of its language', function()
      configure(opts)
      local handlers = handlers_by_filetypes()
      -- Only the languages enabled, with a Mason package
      local names = vim.tbl_keys(handlers)
      table.sort(names)
      assert.same({ 'go', 'lua', 'sh', 'yaml,yaml.helm-values' }, names)
      local bufnr = h.buffer({ filetype = 'lua' })
      handlers.lua({ buf = bufnr, match = 'lua' })
      assert.same({ { 'lua-language-server' } }, calls.install_once)
      -- Not for a filetype the server does not take, nor once installed
      handlers.lua({ buf = bufnr, match = 'vue' })
      installed['lua-language-server'] = true
      handlers.lua({ buf = bufnr, match = 'lua' })
      assert.are.equal(1, #calls.install_once)
    end)

    it('asks the server before installing it for a buffer', function()
      configure(opts)
      local handlers = handlers_by_filetypes()
      local bufnr = h.buffer({ filetype = 'sh' })
      enabled_of.bashls = false
      handlers.sh({ buf = bufnr, match = 'sh' })
      assert.is_nil(calls.install_once)
      enabled_of.bashls = true
      -- No `filetypes` configured: any buffer of the language will do
      handlers.sh({ buf = bufnr, match = 'sh' })
      assert.same({ { 'bash-language-server' } }, calls.install_once)
      -- Nor for a held buffer
      installed['bash-language-server'] = nil
      calls.install_once = nil
      held[bufnr] = true
      handlers.sh({ buf = bufnr, match = 'sh' })
      assert.is_nil(calls.install_once)
      held[bufnr] = nil
      handlers.sh({ buf = bufnr, match = 'sh' })
      assert.same({ { 'bash-language-server' } }, calls.install_once)
      -- A server with no config at all is left alone
      base.bashls = nil
      handlers.sh({ buf = bufnr, match = 'sh' })
      assert.are.equal(1, #calls.install_once)
    end)

    describe('a server shipping its own before_init', function()
      local own_calls
      before_each(function()
        own_calls = {}
        h.write(dir .. '/lsp/golangci_lint_ls.lua', {
          'return { before_init = function(params, config)',
          '  _G.__own_before_init(params, config)',
          'end }',
        })
        h.write(dir .. '/lsp/broken.lua', { 'error("broken")' })
        _G.__own_before_init = function(...) table.insert(own_calls, { ... }) end
        vim.opt.runtimepath:prepend(dir)
      end)
      after_each(function()
        vim.opt.runtimepath:remove(dir)
        _G.__own_before_init = nil
      end)

      it('runs it, then reads the project settings', function()
        configure(opts)
        local config = { name = 'golangci_lint_ls' }
        calls.config.golangci_lint_ls.before_init('params', config)
        assert.same({ { 'params', config } }, own_calls)
        assert.same({ { 'golangci_lint_ls', config } }, calls.local_settings)
      end)

      it('still reads the project settings without one on the path', function()
        vim.fn.delete(dir .. '/lsp/golangci_lint_ls.lua')
        h.write(dir .. '/lsp/golangci_lint_ls.lua', { 'error("broken")' })
        configure(opts)
        local config = { name = 'golangci_lint_ls' }
        calls.config.golangci_lint_ls.before_init('params', config)
        assert.same({}, own_calls)
        assert.same({ { 'golangci_lint_ls', config } }, calls.local_settings)
      end)

      it('keeps a before_init the spec gave the server', function()
        local mine = function() end
        opts.servers.golangci_lint_ls.before_init = mine
        configure(opts)
        assert.are.equal(mine, calls.config.golangci_lint_ls.before_init)
      end)
    end)
  end)
end)
