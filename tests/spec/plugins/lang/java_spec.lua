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
  end)
end)
