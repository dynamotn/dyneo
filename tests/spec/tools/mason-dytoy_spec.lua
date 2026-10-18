local h = require('helpers')

--- mason.nvim, when the configuration has been started on this machine
local mason = vim.fs.joinpath(vim.fn.stdpath('data'), 'lazy', 'mason.nvim')
local has_mason = vim.uv.fs_stat(mason) ~= nil

---@param path string
---@param lines? string[]
local function executable(path, lines)
  h.write(path, lines or { '#!/bin/sh' })
  vim.uv.fs_chmod(path, tonumber('755', 8))
end

---@return table
local function dytoy()
  h.unload('tools.mason-dytoy')
  return require('tools.mason-dytoy')
end

describe('tools.mason-dytoy', function()
  describe('normalize', function()
    it('rewrites a dytoy id into the purl mason reads', function()
      local spec = { source = { id = 'dytoy:opentofu' } }
      assert.are.equal(spec, dytoy().normalize(spec))
      assert.are.equal('pkg:dytoy/opentofu@latest', spec.source.id)
    end)

    it('leaves any other id alone', function()
      for _, id in ipairs({
        'pkg:github/a/b@v1',
        'dytoy:a/b',
        'dytoy:a@1',
        'dytoy:',
      }) do
        local spec = { source = { id = id } }
        dytoy().normalize(spec)
        assert.are.equal(id, spec.source.id)
      end
    end)

    it(
      'leaves a spec without a source alone',
      function() assert.are.same({}, dytoy().normalize({})) end
    )
  end)

  describe('path', function()
    it(
      'leaves out what it is told to skip',
      function()
        assert.are.equal(
          '/usr/bin:/bin',
          dytoy().path('/mason/bin:/usr/bin:/mason/bin/:/bin', {
            skip = { '/mason/bin' },
          })
        )
      end
    )

    it(
      'puts its own directories first',
      function()
        assert.are.equal(
          '/helpers:/usr/bin',
          dytoy().path('/usr/bin', { first = { '/helpers' } })
        )
      end
    )

    it(
      'drops empty entries',
      function() assert.are.equal('/a:/b', dytoy().path(':/a::/b:', {})) end
    )
  end)

  describe('resolve', function()
    local dir, cleanup
    before_each(function()
      dir, cleanup = h.tmpdir()
    end)
    after_each(function() cleanup() end)

    it('skips the directories it is told to', function()
      executable(dir .. '/mason/bin/tool')
      executable(dir .. '/system/tool')
      assert.are.equal(
        dir .. '/system/tool',
        dytoy().resolve('tool', {
          path = dir .. '/mason/bin:' .. dir .. '/system',
          skip = { dir .. '/mason/bin' },
          mise_dir = dir .. '/mise',
        })
      )
    end)

    it('ignores what is not executable', function()
      h.write(dir .. '/first/tool')
      executable(dir .. '/second/tool')
      assert.are.equal(
        dir .. '/second/tool',
        dytoy().resolve('tool', {
          path = dir .. '/first:' .. dir .. '/second',
          mise_dir = dir .. '/mise',
        })
      )
    end)

    it('swaps a versioned mise directory for its shim', function()
      executable(dir .. '/mise/installs/tool/1.0/bin/tool')
      executable(dir .. '/mise/shims/tool')
      assert.are.equal(
        dir .. '/mise/shims/tool',
        dytoy().resolve('tool', {
          path = dir .. '/mise/installs/tool/1.0/bin',
          mise_dir = dir .. '/mise',
        })
      )
    end)

    it('keeps the versioned directory when there is no shim', function()
      executable(dir .. '/mise/installs/tool/1.0/bin/tool')
      assert.are.equal(
        dir .. '/mise/installs/tool/1.0/bin/tool',
        dytoy().resolve('tool', {
          path = dir .. '/mise/installs/tool/1.0/bin',
          mise_dir = dir .. '/mise',
        })
      )
    end)

    it('finds a mise tool PATH does not reach yet', function()
      executable(dir .. '/mise/shims/tool')
      assert.are.equal(
        dir .. '/mise/shims/tool',
        dytoy().resolve('tool', { path = '', mise_dir = dir .. '/mise' })
      )
    end)

    it(
      'answers nothing when the command is nowhere',
      function()
        assert.is_nil(
          dytoy().resolve('tool', { path = dir, mise_dir = dir .. '/mise' })
        )
      end
    )

    it('finds the mise directory through the environment', function()
      local saved = { vim.env.MISE_DATA_DIR, vim.env.XDG_DATA_HOME }
      executable(dir .. '/mise/shims/tool')
      vim.env.MISE_DATA_DIR = dir .. '/mise'
      assert.are.equal(
        dir .. '/mise/shims/tool',
        dytoy().resolve('tool', { path = '' })
      )
      vim.env.MISE_DATA_DIR = nil
      vim.env.XDG_DATA_HOME = dir
      assert.are.equal(
        dir .. '/mise/shims/tool',
        dytoy().resolve('tool', { path = '' })
      )
      vim.env.MISE_DATA_DIR, vim.env.XDG_DATA_HOME = saved[1], saved[2]
    end)
  end)

  describe('askpass', function()
    local restore
    after_each(function()
      if restore then restore() end
      restore = nil
    end)

    it('does not prompt for a token it never handed out', function()
      local module = dytoy()
      restore = h.stub(vim.fn, 'inputsecret', function() error('prompted') end)
      assert.are.equal('', module.askpass('unknown'))
    end)

    it('asks for the tool the token was handed out for', function()
      local module = dytoy()
      module.pending.token = 'fish'
      local asked
      restore = h.stub(vim.fn, 'inputsecret', function(prompt)
        asked = prompt
        return 'hunter2'
      end)
      assert.are.equal('hunter2', module.askpass('token'))
      assert.is_truthy(asked:find('fish', 1, true))
    end)

    it('answers nothing when the prompt is cancelled', function()
      local module = dytoy()
      module.pending.token = 'fish'
      restore = h.stub(
        vim.fn,
        'inputsecret',
        function() error('Keyboard interrupt') end
      )
      assert.are.equal('', module.askpass('token'))
    end)
  end)

  describe('write_helpers', function()
    local dir, cleanup, askpass
    before_each(function()
      dir, cleanup = h.tmpdir()
      -- A `sudo` that prints what it was given, one argument a line
      executable(dir .. '/real-sudo', {
        '#!/bin/sh',
        'printf \'%s\\n\' "$@"',
      })
      askpass = dytoy().write_helpers(dir, {
        sudo = dir .. '/real-sudo',
        nvim = vim.v.progpath,
        server = vim.v.servername ~= '' and vim.v.servername
          or vim.fn.serverstart(),
        token = 'token',
      })
    end)
    after_each(function() cleanup() end)

    ---@param args string[]
    ---@return string[]
    local function sudo(args)
      local result = vim
        .system(vim.list_extend({ dir .. '/sudo' }, args), { text = true })
        :wait()
      assert.are.equal(0, result.code, result.stderr)
      return vim.split(vim.trim(result.stdout), '\n')
    end

    it(
      'makes sudo ask through the helper',
      function()
        assert.are.same(
          { '-A', '-n', 'pacman', '-S', 'fish' },
          sudo({ '-n', 'pacman', '-S', 'fish' })
        )
      end
    )

    it(
      'leaves sudo alone when it reads the password from stdin',
      function() assert.are.same({ '-S', '-v' }, sudo({ '-S', '-v' })) end
    )

    it("reads -S of the command as the command's, not sudo's", function()
      assert.are.same(
        { '-A', 'pacman', '-S', 'fish' },
        sudo({ 'pacman', '-S', 'fish' })
      )
      assert.are.same(
        { '-A', '--', 'pacman', '-S', 'fish' },
        sudo({ '--', 'pacman', '-S', 'fish' })
      )
    end)

    it(
      'reads -S as a value when an option takes it',
      function()
        assert.are.same({ '-A', '-u', '-S', 'id' }, sudo({ '-u', '-S', 'id' }))
      end
    )

    it(
      'finds -S among other short options',
      function() assert.are.same({ '-nS', 'id' }, sudo({ '-nS', 'id' })) end
    )

    it('keeps the helpers to their owner', function()
      for _, name in ipairs({ 'sudo', 'askpass' }) do
        local stat = assert(vim.uv.fs_stat(vim.fs.joinpath(dir, name)))
        assert.are.equal(tonumber('700', 8), bit.band(stat.mode, 511), name)
      end
    end)

    ---@return vim.SystemCompleted
    local function run_askpass()
      local done
      vim.system(
        { askpass },
        { text = true },
        function(result) done = result end
      )
      vim.wait(10000, function() return done ~= nil end, 20)
      return assert(done, 'askpass did not finish')
    end

    it('hands the password from this Neovim to sudo', function()
      local module = require('tools.mason-dytoy')
      module.pending.token = 'fish'
      local restore = h.stub(
        vim.fn,
        'inputsecret',
        function() return 'hunter2' end
      )
      local result = run_askpass()
      restore()
      module.pending.token = nil
      assert.are.equal(0, result.code, result.stderr)
      assert.are.equal('hunter2\n', result.stdout)
    end)

    it('fails when there is no password to hand over', function()
      local result = run_askpass()
      assert.are_not.equal(0, result.code)
      assert.are.equal('', result.stdout)
    end)
  end)

  describe('with mason', function()
    if not has_mason then
      pending('mason.nvim is not installed on this machine')
      return
    end
    before_each(function()
      if not vim.tbl_contains(vim.opt.runtimepath:get(), mason) then
        vim.opt.runtimepath:append(mason)
      end
    end)

    it('names the tool after the purl', function()
      local purl = require('mason-core.purl')
        .parse('pkg:dytoy/opentofu@latest')
        :get_or_throw()
      assert.are.same(
        { tool = 'opentofu' },
        dytoy().parse({}, purl):get_or_throw()
      )
    end)

    it('refuses a namespace', function()
      local purl =
        require('mason-core.purl').parse('pkg:dytoy/a/b@latest'):get_or_throw()
      assert.is_true(dytoy().parse({}, purl):is_failure())
    end)

    it(
      'refuses to pick a version',
      function() assert.is_true(dytoy().get_versions():is_failure()) end
    )

    describe('install', function()
      local dir, cleanup, module, output, env

      --- An install context for a package with one command, `tool`
      ---@param spawn fun(opts: table): any
      local function context(spawn)
        return {
          package = { spec = { bin = { tool = 'bin/tool' } } },
          cwd = {
            get = function() return dir .. '/pkg' end,
          },
          stdio_sink = {
            stdout = function(_, text) table.insert(output, text) end,
          },
          spawn = { dytoy = spawn },
        }
      end

      --- Install `tool` through `ctx`, as mason would, and wait
      local function install(ctx)
        return require('mason-core.async').run_blocking(
          function() return module.install(ctx, { tool = 'tool' }) end
        )
      end

      --- A dytoy on `PATH`, or none
      local function with_dytoy(installed)
        return h.stub(vim.fn, 'executable', function(name)
          if name == 'dytoy' then return installed and 1 or 0 end
          return 1
        end)
      end

      before_each(function()
        dir, cleanup = h.tmpdir()
        output = {}
        module = dytoy()
        env = { vim.env.PATH, vim.env.MISE_DATA_DIR }
        vim.env.PATH = dir .. '/system'
        vim.env.MISE_DATA_DIR = dir .. '/mise'
      end)
      after_each(function()
        vim.env.PATH, vim.env.MISE_DATA_DIR = env[1], env[2]
        cleanup()
      end)

      it('links a command already there, without dytoy', function()
        executable(dir .. '/system/tool')
        local result = install(context(function() error('spawned') end))
        assert.is_true(result:is_success())
        assert.are.equal(
          dir .. '/system/tool',
          vim.uv.fs_readlink(dir .. '/pkg/bin/tool')
        )
        assert.are.same({
          'tool is already installed, linking it.\n',
          'Linking tool -> ' .. dir .. '/system/tool\n',
        }, output)
      end)

      it('needs dytoy for a command that is missing', function()
        local restore = with_dytoy(false)
        local result = install(context(function() error('spawned') end))
        restore()
        assert.is_true(result:is_failure())
        assert.are.equal(
          'dytoy is not installed, and tool is missing.',
          result:err_or_nil()
        )
      end)

      it('runs dytoy with a sudo that asks here, then links', function()
        executable(dir .. '/system/sudo')
        local restore = with_dytoy(true)
        local given
        local result = install(context(function(opts)
          given = opts
          executable(dir .. '/system/tool')
          return require('mason-core.result').success()
        end))
        restore()
        assert.is_true(result:is_success())
        assert.are.same({ '--no-tui', '--tool', 'tool' }, { unpack(given) })
        assert.are.equal('1', given.env.NO_COLOR)
        -- The helpers come first on PATH, with mason's own bin left out
        local helpers = vim.fs.dirname(given.env.SUDO_ASKPASS)
        assert.is_truthy(vim.startswith(given.env.PATH, helpers .. ':'))
        assert.is_falsy(
          given.env.PATH:find(
            require('mason-core.installer.InstallLocation').global():bin(),
            1,
            true
          )
        )
        -- Gone once the install is over, the token with them
        assert.is_nil(vim.uv.fs_stat(helpers))
        assert.are.same({}, module.pending)
        assert.are.equal('Installing tool with dytoy…\n', output[1])
        assert.are.equal(
          dir .. '/system/tool',
          vim.uv.fs_readlink(dir .. '/pkg/bin/tool')
        )
      end)

      it('fails when dytoy could not run, or installed nothing', function()
        local restore = with_dytoy(true)
        local raised = install(context(function() error('boom', 0) end))
        local nothing = install(
          context(function() return require('mason-core.result').success() end)
        )
        restore()
        assert.are.equal('boom', raised:err_or_nil())
        assert.are.equal(
          'dytoy installed nothing that runs "tool".',
          nothing:err_or_nil()
        )
      end)

      it('fails when the link cannot be made', function()
        executable(dir .. '/system/tool')
        vim.fn.mkdir(dir .. '/pkg/bin/tool', 'p')
        local result = install(context(function() error('spawned') end))
        assert.is_true(result:is_failure())
        assert.is_truthy(tostring(result:err_or_nil()):find('EEXIST', 1, true))
      end)
    end)

    it('is the compiler for pkg:dytoy once registered', function()
      local module = dytoy()
      module.register()
      local purl =
        require('mason-core.purl').parse('pkg:dytoy/fish@latest'):get_or_throw()
      assert.are.equal(
        module,
        require('mason-core.installer.compiler')
          .get_compiler(purl)
          :get_or_throw()
      )
    end)
  end)
end)
