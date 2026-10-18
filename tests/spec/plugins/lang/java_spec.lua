local h = require('helpers')

describe('plugins.lang.java', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.java` returns
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/lang/java.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('gives two projects of the same name a workspace each', function()
    local opts = spec('mfussenegger/nvim-jdtls').opts()
    local one = opts.project_name('/work/a/api')
    local other = opts.project_name('/work/b/api')
    assert.matches('^api%-', one)
    assert.matches('^api%-', other)
    assert.are_not.equal(one, other)
    assert.are.equal(one, opts.project_name('/work/a/api'))
    assert.is_nil(opts.project_name(nil))
  end)

  describe('config', function()
    local started, scans, opts

    before_each(function()
      started, scans = {}, {}
      table.insert(
        restores,
        h.stub(package.loaded, 'jdtls', {
          start_or_attach = function(config, _, start_opts)
            table.insert(started, {
              config = config,
              bufnr = start_opts and start_opts.bufnr,
            })
          end,
          setup_dap = function() end,
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'jdtls.dap', {
          setup_dap_main_class_configs = function() table.insert(scans, true) end,
        })
      )
      table.insert(restores, h.stub(package.loaded, 'jdtls.tests', {}))
      table.insert(
        restores,
        h.stub(package.loaded, 'which-key', { add = function() end })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'mason-registry', {
          is_installed = function(name) return name == 'java-debug-adapter' end,
        })
      )
      local plugin = require('util.plugin')
      table.insert(
        restores,
        h.stub(plugin, 'has', function(name) return name ~= 'blink.cmp' end)
      )
      table.insert(
        restores,
        h.stub(
          vim.lsp,
          'get_client_by_id',
          function(id) return { id = id, name = 'jdtls' } end
        )
      )
      opts = spec('mfussenegger/nvim-jdtls').opts()
      opts.root_dir = function(path) return vim.fs.dirname(path) end
    end)
    after_each(
      function() pcall(vim.api.nvim_del_augroup_by_name, 'dyneo_jdtls') end
    )

    it('starts the server for the buffer that turned Java', function()
      local first = h.buffer({ name = '/work/one/A.java' })
      vim.api.nvim_set_current_buf(first)
      spec('mfussenegger/nvim-jdtls').config(nil, opts)
      assert.are.equal(first, started[1].bufnr)

      -- Set while another buffer is the current one
      local other = h.buffer({ name = '/work/two/B.java', filetype = 'java' })
      assert.are.equal(first, vim.api.nvim_get_current_buf())
      local last = started[#started]
      assert.are.equal(other, last.bufnr)
      assert.are.equal('/work/two', last.config.root_dir)
      local data = last.config.cmd[vim.fn.index(last.config.cmd, '-data') + 2]
      assert.matches('/jdtls/two%-%x+/workspace$', data)
    end)

    it('scans for main classes once per server', function()
      vim.api.nvim_set_current_buf(h.buffer({ name = '/work/three/A.java' }))
      spec('mfussenegger/nvim-jdtls').config(nil, opts)
      for _, attach in ipairs({ { 7, 'C' }, { 7, 'D' }, { 8, 'E' } }) do
        vim.api.nvim_exec_autocmds('LspAttach', {
          buffer = h.buffer({ name = '/work/three/' .. attach[2] .. '.java' }),
          data = { client_id = attach[1] },
        })
      end
      assert.are.equal(2, #scans)
    end)

    it('lets the project extend or replace the server config', function()
      vim.api.nvim_set_current_buf(h.buffer({ name = '/work/four/A.java' }))
      opts.jdtls = { settings = { java = { extra = true } } }
      spec('mfussenegger/nvim-jdtls').config(nil, opts)
      assert.is_true(started[#started].config.settings.java.extra)
      assert.are.equal('/work/four', started[#started].config.root_dir)

      opts.jdtls = function(config) config.cmd = { 'custom' } end
      spec('mfussenegger/nvim-jdtls').config(nil, opts)
      assert.same({ 'custom' }, started[#started].config.cmd)
      opts.jdtls = function() return { cmd = { 'replaced' } } end
      spec('mfussenegger/nvim-jdtls').config(nil, opts)
      assert.same({ cmd = { 'replaced' } }, started[#started].config)
    end)

    it("finds the root by jdtls's own markers", function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/proj/pom.xml')
      local original = spec('mfussenegger/nvim-jdtls').opts().root_dir
      table.insert(
        restores,
        h.stub(
          vim.lsp,
          'config',
          setmetatable({ jdtls = { root_markers = { 'pom.xml' } } }, {
            __index = vim.lsp.config,
          })
        )
      )
      assert.are.equal(dir .. '/proj', original(dir .. '/proj/src/A.java'))
      cleanup()
    end)

    describe('with java-test', function()
      local dir, cleanup, added, tests

      before_each(function()
        dir, cleanup = h.tmpdir()
        added, tests = {}, {}
        h.write(dir .. '/share/java-test/runner.jar')
        h.write(
          dir
            .. '/share/java-debug-adapter/com.microsoft.java.debug.plugin-0.1.jar'
        )
        table.insert(restores, h.stub(vim.env, 'MASON', dir))
        table.insert(
          restores,
          h.stub(package.loaded, 'mason-registry', {
            is_installed = function() return true end,
          })
        )
        table.insert(
          restores,
          h.stub(package.loaded, 'which-key', {
            add = function(spec_) table.insert(added, spec_) end,
          })
        )
        table.insert(
          restores,
          h.stub(package.loaded, 'jdtls.dap', {
            setup_dap_main_class_configs = function() end,
            test_class = function(o) table.insert(tests, { 'class', o }) end,
            test_nearest_method = function(o)
              table.insert(tests, { 'nearest', o })
            end,
            pick_test = 'pick',
          })
        )
      end)
      after_each(function() cleanup() end)

      --- The test keys which-key was given for the buffer the server attached
      --- to, by lhs
      ---@return table<string, table>
      local function attach()
        added = {}
        -- A root of its own: a name a buffer already holds cannot be given again
        vim.api.nvim_set_current_buf(h.buffer({ name = dir .. '/A.java' }))
        spec('mfussenegger/nvim-jdtls').config(nil, opts)
        vim.api.nvim_exec_autocmds('LspAttach', {
          buffer = vim.api.nvim_get_current_buf(),
          data = { client_id = 9 },
        })
        local keys = {}
        for _, mapping in ipairs(added[#added][1]) do
          if type(mapping) == 'table' then keys[mapping[1]] = mapping end
        end
        return keys
      end

      it('hands jdtls both bundles and maps the runner', function()
        local keys = attach()
        local bundles = started[#started].config.init_options.bundles
        assert.are.equal(2, #bundles)
        assert.matches('java%-test/runner%.jar$', bundles[2])
        assert.are.equal(3, #added)
        assert.are.equal('pick', keys['<localleader>T'][2])
        keys['<localleader>t'][2]()
        keys['<localleader>r'][2]()
        assert.same({
          { 'class', { config_overrides = nil } },
          { 'nearest', { config_overrides = nil } },
        }, tests)
      end)

      it('passes the overrides of the test config on', function()
        opts.test = { config_overrides = { vmArgs = '-ea' } }
        local keys = attach()
        keys['<localleader>t'][2]()
        keys['<localleader>r'][2]()
        assert.same({ vmArgs = '-ea' }, tests[1][2].config_overrides)
        assert.same({ vmArgs = '-ea' }, tests[2][2].config_overrides)
      end)
    end)
  end)
end)
