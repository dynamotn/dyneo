local h = require('helpers')

--- The mason.nvim spec
---@return table
local function spec()
  for _, plugin in
    ipairs(dofile(h.root .. '/lua/plugins/integration/tool_manager.lua'))
  do
    if plugin[1] == 'mason-org/mason.nvim' then return plugin end
  end
  error('no mason spec')
end

describe('plugins.integration.tool_manager: mason.nvim', function()
  local restores, registry, handlers, packages, loaded, triggered, setup_opts

  --- A fake Mason package
  ---@param state 'installed'|'installing'|'absent'
  ---@return table
  local function package_(state)
    return {
      installs = 0,
      is_installed = function() return state == 'installed' end,
      is_installing = function() return state == 'installing' end,
      install = function(self) self.installs = self.installs + 1 end,
    }
  end

  before_each(function()
    h.globals()
    handlers, packages, loaded, triggered = {}, {}, {}, {}
    registry = {
      on = function(_, event, fn) handlers[event] = fn end,
      refresh = function(fn) fn() end,
      get_package = function(name)
        return packages[name] or error('unknown package ' .. name)
      end,
    }
    restores = {
      h.stub(package.loaded, 'mason', {
        setup = function(opts) setup_opts = opts end,
      }),
      h.stub(package.loaded, 'mason-registry', registry),
      h.stub(package.loaded, 'lazy', {
        load = function(opts) vim.list_extend(loaded, opts.plugins) end,
      }),
      h.stub(
        require('lazy.core.handler.event'),
        'trigger',
        function(opts)
          table.insert(
            triggered,
            { event = opts.event, buf = vim.api.nvim_get_current_buf() }
          )
        end
      ),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('reads the own registries ahead of the upstream one', function()
    assert.same({
      'lua:tools.mason-registry',
      'lua:dy-mason-registry',
      'github:mason-org/mason-registry',
    }, spec().opts.registries)
    -- `lua:dy-mason-registry` is a module of this plugin
    assert.same(
      { { 'dynamotn/mason-registry', dev = true } },
      spec().dependencies
    )
  end)

  -- mason keys the index it fetched on the list of registries, and fetches
  -- again for any other list
  it('is given the same registries by the scripts and CI', function()
    local wanted = table.concat(
      vim.tbl_map(
        function(r) return "'" .. r .. "'" end,
        spec().opts.registries
      ),
      ', '
    )
    for _, file in ipairs({
      'scripts/install-parsers.lua',
      '.github/workflows/check.yml',
    }) do
      local text = table.concat(vim.fn.readfile(h.root .. '/' .. file), ' ')
      local found = text:match('registries = {%s*(.-),?%s*}')
      assert.equals(wanted, found and found:gsub(',%s+', ', '), file)
    end
  end)

  it('installs each wanted tool once, skipping the unknown', function()
    packages.a = package_('absent')
    packages.b = package_('installed')
    packages.c = package_('installing')
    local opts = { ensure_installed = { 'a', 'a', 'b', 'c', 'nope' } }
    spec().config(nil, opts)
    assert.equals(opts, setup_opts)
    assert.equals(1, packages.a.installs)
    assert.equals(0, packages.b.installs)
    assert.equals(0, packages.c.installs)
    -- swapson is not part of this configuration
    assert.same({}, loaded)
  end)

  it('loads swapson when it is part of the configuration', function()
    local has = h.stub(
      require('util.plugin'),
      'has',
      function(name) return name == 'swapson.nvim' end
    )
    spec().config(nil, { ensure_installed = {} })
    has()
    assert.same({ 'swapson.nvim' }, loaded)
  end)

  it(
    'runs the FileType handlers of every file on screen after an install',
    function()
      spec().config(nil, { ensure_installed = {} })
      local shown = h.buffer({ filetype = 'lua', lines = { 'x' } })
      vim.api.nvim_set_current_buf(shown)
      vim.cmd.split()
      local untyped = h.buffer({ lines = { 'y' } })
      vim.api.nvim_set_current_buf(untyped)
      vim.cmd.split()
      local scratch = vim.api.nvim_create_buf(false, true)
      vim.bo[scratch].filetype = 'mason'
      vim.api.nvim_set_current_buf(scratch)
      -- The same buffer in two windows is set up once
      vim.cmd.split()
      vim.api.nvim_set_current_buf(shown)
      handlers['package:install:success']()
      vim.wait(1000, function() return #triggered > 0 end, 10)
      vim.wait(100, function() return false end, 10)
      assert.same({ { event = 'FileType', buf = shown } }, triggered)
    end
  )

  describe('vale', function()
    local notes, ran, run_result, dir, cleanup, path

    before_each(function()
      dir, cleanup = h.tmpdir()
      notes, ran = {}, {}
      path = vim.env.PATH
      vim.env.PATH = dir
      vim.env.VALE_CONFIG_PATH = nil
      local system = require('util.system')
      table.insert(
        restores,
        h.stub(system, 'run', function(cmd, opts, on_done)
          table.insert(ran, cmd)
          assert.is_number(opts.timeout)
          vim.schedule(function() on_done(run_result) end)
        end)
      )
      table.insert(
        restores,
        h.stub(
          vim,
          'notify',
          function(msg, level) table.insert(notes, { msg = msg, level = level }) end
        )
      )
      spec().init()
      -- Nothing until mason has loaded
      assert.is_nil(handlers['package:install:success'])
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'LazyLoad', data = 'mason.nvim' }
      )
    end)
    after_each(function()
      vim.env.PATH = path
      vim.env.VALE_CONFIG_PATH = nil
      cleanup()
    end)

    --- Report an install of `name`, and wait for what follows it
    ---@param name string
    local function installed(name)
      handlers['package:install:success']({ name = name })
      vim.wait(500, function() return #notes >= 2 end, 5)
    end

    it('syncs its styles right after it is installed', function()
      h.write(dir .. '/vale', { '#!/bin/sh' })
      vim.fn.setfperm(dir .. '/vale', 'rwxr-xr-x')
      run_result = { code = 0 }
      installed('vale')
      assert.same({ { dir .. '/vale', 'sync' } }, ran)
      assert.equals('Synced vale styles', notes[2].msg)
    end)

    it('syncs the configuration `$VALE_CONFIG_PATH` names', function()
      h.write(dir .. '/vale', { '#!/bin/sh' })
      vim.fn.setfperm(dir .. '/vale', 'rwxr-xr-x')
      vim.env.VALE_CONFIG_PATH = '/etc/vale.ini'
      run_result = { code = 1, stderr = 'no such config' }
      installed('vale')
      assert.same(
        { { dir .. '/vale', '--config', '/etc/vale.ini', 'sync' } },
        ran
      )
      assert.equals(vim.log.levels.ERROR, notes[2].level)
      assert.truthy(notes[2].msg:find('no such config', 1, true))
    end)

    it(
      'does nothing for another package, or a vale that is not there',
      function()
        installed('stylua')
        installed('vale')
        vim.wait(100, function() return false end, 10)
        assert.same({}, ran)
        assert.same({}, notes)
      end
    )
  end)
end)
