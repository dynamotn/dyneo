local h = require('helpers')

local file = h.root .. '/lua/plugins/treesitter/parser.lua'

describe('plugins.treesitter.parser', function()
  local restores, treesitter, parsers, installs, errors, TS, Plugin

  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  --- A fresh copy of the spec, with its own `attempted` set
  ---@return table
  local function spec() return dofile(file)[1] end

  before_each(function()
    h.globals()
    -- The `FileType` dispatcher keeps its handlers between tests
    h.unload('util.lazy_install', 'util.treesitter')
    restores = {}
    installs, errors = {}, {}
    treesitter = {
      installed = { 'lua' },
      get_installed = function() return treesitter.installed end,
      setup = function(opts) treesitter.setup_opts = opts end,
      update = function(...) treesitter.updated = { ... } end,
      install = function(langs, opts)
        table.insert(installs, { langs = langs, opts = opts })
        return {
          await = function(_, cb)
            vim.list_extend(treesitter.installed, langs)
            cb()
          end,
        }
      end,
    }
    parsers = { gherkin = {} }
    stub(package.loaded, 'nvim-treesitter', treesitter)
    stub(package.loaded, 'nvim-treesitter.parsers', parsers)
    TS = require('util.treesitter')
    Plugin = require('util.plugin')
    -- The tree-sitter CLI and a compiler are not what is under test
    stub(TS, 'build', function(cb) cb() end)
    stub(Plugin, 'error', function(msg) table.insert(errors, msg) end)
    DyNeo.bundle_languages = { 'cue', 'd2' }
    DyNeo.enabled_languages = { 'cucumber', 'cue', 'd2' }
  end)
  after_each(function()
    for _, group in ipairs({
      'dyneo_treesitter_parsers',
      'dyneo_treesitter',
      'dy_lazy_install',
    }) do
      pcall(vim.api.nvim_del_augroup_by_name, group)
    end
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  describe('build', function()
    it('asks for a restart on the release branch', function()
      treesitter.get_installed = nil
      spec().build()
      assert.equals(1, #errors)
      assert.is_truthy(errors[1]:find('restart', 1, true))
      assert.is_nil(treesitter.updated)
    end)

    it('updates the parsers once the toolchain is there', function()
      spec().build()
      assert.same({}, errors)
      assert.same({ nil, { summary = true } }, treesitter.updated)
    end)
  end)

  describe('config', function()
    it('asks for an update on the release branch', function()
      treesitter.get_installed = nil
      local plugin = spec()
      plugin.config(nil, plugin.opts)
      assert.equals(1, #errors)
      assert.is_nil(treesitter.setup_opts)
    end)

    it('lays the parsers of the languages over nvim-treesitter', function()
      local plugin = spec()
      local opts = vim.deepcopy(plugin.opts)
      plugin.config(nil, opts)
      assert.equals(opts, treesitter.setup_opts)
      -- Registered for the filetypes of the language
      assert.equals('gherkin', vim.treesitter.language.get_lang('cucumber'))
      assert.equals('d2', vim.treesitter.language.get_lang('d2'))

      -- Only on `:TSUpdate`, which rewrites nvim-treesitter's list
      assert.is_nil(parsers.gherkin.install_info)
      assert.is_nil(parsers.d2)
      vim.api.nvim_exec_autocmds('User', { pattern = 'TSUpdate' })
      local languages = require('config.languages')
      assert.equals(
        languages.cucumber.parser.install_info,
        parsers.gherkin.install_info
      )
      assert.equals(languages.d2.parser.install_info, parsers.d2.install_info)
      assert.equals(0, parsers.d2.tier)
    end)

    it('installs the bundle at once, without repeats', function()
      local plugin = spec()
      local opts = vim.deepcopy(plugin.opts)
      table.insert(opts.ensure_installed, 'lua')
      plugin.config(nil, opts)
      -- The bundle's parsers and what their queries inject
      assert.is_true(vim.list_contains(opts.ensure_installed, 'cue'))
      assert.is_true(vim.list_contains(opts.ensure_installed, 'd2'))
      assert.is_true(vim.list_contains(opts.ensure_installed, 'javascript'))
      assert.is_false(vim.list_contains(opts.ensure_installed, 'gherkin'))
      local seen = {}
      for _, name in ipairs(opts.ensure_installed) do
        assert.is_nil(seen[name], name .. ' twice')
        seen[name] = true
      end
      -- Installed ones are left out of the install
      assert.equals(1, #installs)
      assert.is_false(vim.list_contains(installs[1].langs, 'lua'))
      assert.is_true(vim.list_contains(installs[1].langs, 'cue'))
      assert.same({ summary = true }, installs[1].opts)
      assert.is_true(TS.get_installed().cue)
    end)

    it(
      'checks a parser by its own name, not a filetype given to another',
      function()
        -- `c` buffers go to the `cpp` parser, which says nothing of `c`'s
        treesitter.installed = { 'lua', 'cpp' }
        local plugin = spec()
        local opts = vim.deepcopy(plugin.opts)
        table.insert(opts.ensure_installed, 'c')
        table.insert(opts.ensure_installed, 'cpp')
        plugin.config(nil, opts)
        assert.equals('cpp', vim.treesitter.language.get_lang('c'))
        assert.is_true(vim.list_contains(installs[1].langs, 'c'))
        assert.is_false(vim.list_contains(installs[1].langs, 'cpp'))
      end
    )

    it('installs nothing when the bundle is there', function()
      stub(TS, 'get_installed', function()
        return setmetatable({}, { __index = function() return true end })
      end)
      local plugin = spec()
      plugin.config(nil, vim.deepcopy(plugin.opts))
      assert.same({}, installs)
    end)

    it('installs the parser of a language on its first buffer', function()
      DyNeo.bundle_languages = {}
      local plugin = spec()
      plugin.config(nil, vim.deepcopy(plugin.opts))
      installs = {}

      local bufnr = h.buffer({ filetype = 'cucumber' })
      assert.equals(1, #installs)
      assert.same({ 'gherkin' }, installs[1].langs)
      assert.is_true(TS.get_installed().gherkin)
      -- The buffer is set up again, not reloaded
      assert.equals('cucumber', vim.bo[bufnr].filetype)

      -- Now installed: a second buffer asks for nothing
      h.buffer({ filetype = 'cucumber' })
      assert.equals(1, #installs)
    end)

    it('tries a parser that fails to build once a session', function()
      DyNeo.bundle_languages = {}
      treesitter.install = function(langs, opts)
        table.insert(installs, { langs = langs, opts = opts })
        return { await = function() end }
      end
      local plugin = spec()
      plugin.config(nil, vim.deepcopy(plugin.opts))
      installs = {}

      h.buffer({ filetype = 'd2' })
      assert.equals(1, #installs)
      assert.same({ 'd2', 'javascript', 'typescript' }, installs[1].langs)
      h.buffer({ filetype = 'd2' })
      assert.equals(1, #installs)
    end)

    it('starts the features a filetype has parser and queries for', function()
      local plugin = spec()
      local opts = vim.deepcopy(plugin.opts)
      plugin.config(nil, opts)
      local queries = {}
      stub(
        TS,
        'have_query',
        function(lang, query) return queries[lang .. ':' .. query] == true end
      )
      local started = {}
      stub(
        vim.treesitter,
        'start',
        function(buf) table.insert(started, buf) end
      )

      -- No parser: nothing happens
      local text = h.buffer({ filetype = 'text' })
      assert.same({}, started)
      assert.is_nil(vim.bo[text].indentexpr:find('util.treesitter', 1, true))

      -- A parser, and only the highlights query
      queries['lua:highlights'] = true
      local lua = h.buffer({ filetype = 'lua' })
      assert.same({ lua }, started)
      assert.is_nil(vim.bo[lua].indentexpr:find('util.treesitter', 1, true))

      queries['lua:indents'] = true
      queries['lua:folds'] = true
      -- Current first: the fold options are the window's
      local full = h.buffer({})
      vim.api.nvim_set_current_buf(full)
      vim.bo[full].filetype = 'lua'
      assert.same({ lua, full }, started)
      assert.equals(
        "v:lua.require'util.treesitter'.indentexpr()",
        vim.bo[full].indentexpr
      )
      assert.equals('expr', vim.wo.foldmethod)
      assert.equals(
        "v:lua.require'util.treesitter'.foldexpr()",
        vim.wo.foldexpr
      )
    end)

    it('leaves a language out of a feature that disables it', function()
      local plugin = spec()
      local opts = vim.deepcopy(plugin.opts)
      opts.highlight.disable = { 'lua' }
      opts.indent.enable = false
      plugin.config(nil, opts)
      stub(TS, 'have_query', function() return true end)
      local started = {}
      stub(
        vim.treesitter,
        'start',
        function(buf) table.insert(started, buf) end
      )

      local lua = h.buffer({})
      vim.api.nvim_set_current_buf(lua)
      vim.bo[lua].filetype = 'lua'
      assert.same({}, started)
      assert.is_nil(vim.bo[lua].indentexpr:find('util.treesitter', 1, true))
      assert.equals('expr', vim.wo.foldmethod)
    end)
  end)
end)
