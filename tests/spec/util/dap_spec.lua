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

    it('reads the map off the plugin file under lazy.nvim, once', function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/source.lua', {
        'return { nvim_dap_to_package = { python = "debugpy" } }',
      })
      local asked = {}
      local restores = {
        h.stub(package.loaded, 'lazy.core.config', {}),
        h.stub(package.loaded, 'util.plugin', {
          get_plugin_path = function(name, path)
            table.insert(asked, { name, path })
            return dir .. '/source.lua'
          end,
        }),
      }
      h.unload('util.dap')
      local fresh = require('util.dap')
      assert.equals('debugpy', fresh.package('python'))
      assert.is_nil(fresh.package('unknown'))
      assert.same({
        { 'mason-nvim-dap.nvim', 'lua/mason-nvim-dap/mappings/source.lua' },
      }, asked)
      for i = #restores, 1, -1 do
        restores[i]()
      end
      h.unload('util.dap')
      cleanup()
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

    it('goes by the first rule matching in the nearest directory', function()
      touch('webpack.config.js')
      touch('next.config.js')
      -- List webpack's first, as a disk may
      local dir_of = vim.fs.dir
      local restore = h.stub(vim.fs, 'dir', function(path, ...)
        local names = {}
        for file in dir_of(path, ...) do
          table.insert(names, file)
        end
        table.sort(names, function(a, b) return a > b end)
        local i = 0
        return function()
          i = i + 1
          return names[i], names[i] and 'file'
        end
      end)
      local url = dap_util.dev_server_url(buffer('src/page.tsx', 'tsx'))
      restore()
      assert.equals('http://localhost:3000', url)
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

  describe('guard_launch_json', function()
    local dir, cleanup, cwd, restores, asked, verdict, fake

    before_each(function()
      dir, cleanup = h.tmpdir()
      cwd = vim.fn.getcwd()
      vim.cmd.cd(dir)
      asked, verdict = 0, nil
      restores = {
        h.stub(vim.secure, 'read', function(path)
          asked = asked + 1
          assert.equals(dir .. '/.vscode/launch.json', path)
          return verdict
        end),
      }
      fake = {
        providers = {
          configs = {
            ['dap.launch.json'] = function()
              return { { name = 'from launch.json' } }
            end,
          },
        },
      }
      h.unload('util.dap')
      require('util.dap').guard_launch_json(fake)
    end)
    after_each(function()
      for i = #restores, 1, -1 do
        restores[i]()
      end
      vim.cmd.cd(cwd)
      cleanup()
      h.unload('util.dap')
    end)

    local function configs() return fake.providers.configs['dap.launch.json'](0) end

    it('asks nothing when there is no launch.json', function()
      assert.same({}, configs())
      assert.equals(0, asked)
    end)

    it('reads a trusted launch.json', function()
      h.write(dir .. '/.vscode/launch.json', { '{}' })
      verdict = '{}'
      assert.same({ { name = 'from launch.json' } }, configs())
    end)

    it('gives nothing from an untrusted one and asks once', function()
      h.write(dir .. '/.vscode/launch.json', { '{}' })
      assert.same({}, configs())
      assert.same({}, configs())
      assert.equals(1, asked)
    end)
  end)
end)
