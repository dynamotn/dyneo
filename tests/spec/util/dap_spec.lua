local h = require('helpers')
local dap_util = require('util.dap')

describe('util.dap', function()
  describe('name', function()
    it(
      'returns a string spec as is',
      function() assert.equals('python', dap_util.name('python')) end
    )
    it(
      'returns the first item of a table spec',
      function()
        assert.equals(
          'perl',
          dap_util.name({ 'perl', mason = { package = 'x' } })
        )
      end
    )
  end)

  describe('package', function()
    after_each(
      function() package.loaded['mason-nvim-dap.mappings.source'] = nil end
    )

    it(
      'prefers the package of a table spec',
      function()
        assert.equals(
          'perl-debug-adapter',
          dap_util.package({
            'perl',
            mason = { package = 'perl-debug-adapter' },
          })
        )
      end
    )

    it('maps a name through mason-nvim-dap', function()
      package.loaded['mason-nvim-dap.mappings.source'] =
        { nvim_dap_to_package = { python = 'debugpy' } }
      assert.equals('debugpy', dap_util.package('python'))
      assert.is_nil(dap_util.package('unknown'))
    end)

    it(
      'is nil when mason-nvim-dap is not available',
      function() assert.is_nil(dap_util.package('python')) end
    )
  end)

  describe('is_mapped', function()
    it('is true only for a name', function()
      assert.is_true(dap_util.is_mapped('python'))
      assert.is_false(dap_util.is_mapped({ 'perl', mason = { package = 'p' } }))
    end)
  end)

  describe('codelldb', function()
    local dap
    before_each(function()
      dap = { adapters = {} }
      package.loaded['dap'] = dap
      package.loaded['dap.utils'] = { pick_process = function() end }
    end)
    after_each(function()
      package.loaded['dap'] = nil
      package.loaded['dap.utils'] = nil
    end)

    it('registers the adapter', function()
      dap_util.codelldb_adapter()
      assert.equals('server', dap.adapters.codelldb.type)
      assert.equals('codelldb', dap.adapters.codelldb.executable.command)
    end)

    it('keeps an adapter registered before', function()
      local existing = { type = 'executable' }
      dap.adapters.codelldb = existing
      dap_util.codelldb_adapter()
      assert.equals(existing, dap.adapters.codelldb)
    end)

    it('builds launch and attach configurations', function()
      local configs = dap_util.codelldb_configurations('build')
      assert.equals(2, #configs)
      assert.equals('launch', configs[1].request)
      assert.equals('attach', configs[2].request)
      assert.equals(package.loaded['dap.utils'].pick_process, configs[2].pid)

      local prompt
      local restore = h.stub(vim.fn, 'input', function(_, default)
        prompt = default
        return '/bin/true'
      end)
      local program = configs[1].program()
      restore()
      assert.equals('/bin/true', program)
      assert.equals(vim.fn.getcwd() .. '/build', prompt)
    end)
  end)

  describe('dev_server_url', function()
    local dir, cleanup, buffers
    before_each(function()
      dir, cleanup = h.tmpdir()
      buffers = {}
    end)
    after_each(function()
      for _, bufnr in ipairs(buffers) do
        vim.api.nvim_buf_delete(bufnr, { force = true })
      end
      cleanup()
    end)

    ---@param path string relative to `dir`
    ---@param filetype? string
    local function buffer(path, filetype)
      local bufnr = h.buffer({ name = dir .. '/' .. path, filetype = filetype })
      table.insert(buffers, bufnr)
      return bufnr
    end

    local function touch(path)
      vim.fn.mkdir(vim.fs.dirname(dir .. '/' .. path), 'p')
      vim.fn.writefile({}, dir .. '/' .. path)
    end

    it('takes the port from the nearest config file', function()
      touch('angular.json')
      touch('apps/web/vite.config.mts')
      assert.equals(
        'http://localhost:5173',
        dap_util.dev_server_url(buffer('apps/web/src/main.ts', 'typescript'))
      )
      assert.equals(
        'http://localhost:4200',
        dap_util.dev_server_url(buffer('src/app.ts', 'typescript'))
      )
    end)

    it('knows Astro, Gatsby and webpack', function()
      touch('site/astro.config.mjs')
      touch('blog/gatsby-config.ts')
      touch('app/webpack.config.cjs')
      assert.equals(
        'http://localhost:4321',
        dap_util.dev_server_url(buffer('site/src/index.ts', 'typescript'))
      )
      assert.equals(
        'http://localhost:8000',
        dap_util.dev_server_url(buffer('blog/src/page.tsx', 'typescriptreact'))
      )
      assert.equals(
        'http://localhost:8080',
        dap_util.dev_server_url(buffer('app/src/main.js', 'javascript'))
      )
    end)

    it('lets the config file win over the filetype', function()
      touch('vue.config.js')
      assert.equals(
        'http://localhost:8080',
        dap_util.dev_server_url(buffer('src/App.vue', 'vue'))
      )
    end)

    it('falls back on the filetype, then on port 3000', function()
      assert.equals(
        'http://localhost:4200',
        dap_util.dev_server_url(buffer('a.html', 'htmlangular'))
      )
      assert.equals(
        'http://localhost:4321',
        dap_util.dev_server_url(buffer('c.astro', 'astro'))
      )
      assert.equals(
        'http://localhost:3000',
        dap_util.dev_server_url(buffer('b.ts', 'typescript'))
      )
    end)
  end)
end)
