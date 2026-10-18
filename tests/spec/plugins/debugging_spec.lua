local h = require('helpers')

describe('plugins.executor.debugging: run with args', function()
  local restores, typed, args_of

  before_each(function()
    h.globals()
    local before
    restores = {
      h.stub(package.loaded, 'dap', {
        continue = function(opts) before = opts.before end,
      }),
      h.stub(package.loaded, 'dap.utils', {
        splitstr = function(str)
          return vim.split(str, ' ', { trimempty = true })
        end,
      }),
      h.stub(vim.fn, 'input', function() return typed end),
    }
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/debugging.lua'))
    do
      if plugin[1] == 'mfussenegger/nvim-dap' then
        for _, key in ipairs(plugin.keys) do
          if key[1] == '<leader>da' then key[2]() end
        end
      end
    end
    --- The arguments a run gets from what is typed
    ---@param config table
    ---@return string[]|string
    args_of = function(config) return before(config).args() end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('expands each argument on its own', function()
    typed = '% -v ~/x *.nomatch'
    local bufnr = h.buffer({ name = '/tmp/dy/prog.py' })
    vim.api.nvim_set_current_buf(bufnr)
    assert.same(
      { '/tmp/dy/prog.py', '-v', vim.fs.normalize('~/x'), '*.nomatch' },
      args_of({})
    )
  end)

  it('keeps the line whole for Java', function()
    typed = '-v "a b" ~/x'
    assert.are.equal(
      '-v "a b" ' .. vim.fs.normalize('~/x'),
      args_of({ type = 'java' })
    )
  end)
end)

describe('plugins.executor.debugging: nvim-dap', function()
  local restores, plugins, specs

  ---@param name string
  ---@return table
  local function spec(name)
    for _, plugin in ipairs(specs) do
      if plugin[1] == name then return plugin end
    end
    error('no spec ' .. name)
  end

  ---@param plugin table
  ---@param lhs string
  ---@return fun()
  local function key(plugin, lhs)
    for _, mapping in ipairs(plugin.keys) do
      if mapping[1] == lhs then return mapping[2] end
    end
    error('no key ' .. lhs)
  end

  before_each(function()
    h.globals()
    plugins = {}
    restores = {
      h.stub(
        package.loaded,
        'lazy.core.config',
        { spec = { plugins = plugins }, plugins = {} }
      ),
      h.stub(package.loaded, 'lazy.core.plugin', {
        values = function(plugin, field)
          assert.are.equal('opts', field)
          return plugin.opts
        end,
      }),
    }
    specs = dofile(h.root .. '/lua/plugins/executor/debugging.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  describe('setup', function()
    local mason_setup, guarded, dap, vscode

    before_each(function()
      dap, vscode = {}, {}
      restores[#restores + 1] = h.stub(package.loaded, 'dap', dap)
      restores[#restores + 1] = h.stub(package.loaded, 'dap.ext.vscode', vscode)
      restores[#restores + 1] = h.stub(package.loaded, 'mason-nvim-dap', {
        setup = function(opts) mason_setup = opts end,
      })
      restores[#restores + 1] = h.stub(package.loaded, 'util.dap', {
        guard_launch_json = function(module) guarded = module end,
      })
      mason_setup, guarded = nil, nil
    end)

    it('defines the signs and reads launch.json as JSONC', function()
      spec('mfussenegger/nvim-dap').config()
      assert.is_nil(mason_setup)
      assert.are.equal(dap, guarded)
      assert.are.equal(require('util.jsonc').decode, vscode.json_decode)
      local stopped = vim.fn.sign_getdefined('DapStopped')[1]
      assert.are.equal('DiagnosticWarn', stopped.texthl)
      assert.are.equal('DapStoppedLine', stopped.linehl)
      assert.are.equal('DapStoppedLine', stopped.numhl)
      local breakpoint = vim.fn.sign_getdefined('DapBreakpoint')[1]
      assert.are.equal('DiagnosticInfo', breakpoint.texthl)
      assert.is_nil(breakpoint.linehl)
      assert.are.equal(
        'Visual',
        vim.api.nvim_get_hl(0, { name = 'DapStoppedLine' }).link
      )
    end)

    it('sets mason-nvim-dap up once every adapter is', function()
      plugins['mason-nvim-dap.nvim'] = { opts = { handlers = { 'x' } } }
      spec('mfussenegger/nvim-dap').config()
      assert.are.same({ handlers = { 'x' } }, mason_setup)
    end)
  end)

  describe('dap-view', function()
    local view, hovered, toggled

    before_each(function()
      hovered, toggled = 'untouched', 0
      restores[#restores + 1] = h.stub(package.loaded, 'dap-view', {
        hover = function(expr) hovered = expr end,
        toggle = function() toggled = toggled + 1 end,
      })
      view = spec('igorlfs/nvim-dap-view')
    end)

    it('toggles the view', function()
      key(view, '<leader>du')()
      assert.are.equal(1, toggled)
    end)

    it('evaluates the word under the cursor', function()
      key(view, '<leader>de')()
      assert.is_nil(hovered)
    end)

    it('evaluates the selection in visual mode', function()
      local bufnr = h.buffer({ lines = { 'foo.bar', 'baz' } })
      vim.api.nvim_set_current_buf(bufnr)
      restores[#restores + 1] = h.stub(
        vim.fn,
        'mode',
        function() return 'V' end
      )
      restores[#restores + 1] = h.stub(vim.fn, 'getregion', function(_, _, opts)
        assert.are.equal('V', opts.type)
        return { 'foo.bar', 'baz' }
      end)
      key(view, '<leader>de')()
      assert.are.equal('foo.bar\nbaz', hovered)
    end)
  end)

  describe('adapters from Mason', function()
    local installed, handlers, mason

    before_each(function()
      installed, handlers = {}, {}
      restores[#restores + 1] = h.stub(package.loaded, 'config.languages', {
        sh = {
          filetypes = { 'sh', 'bash' },
          dap = { 'bash', { 'custom', mason = { package = 'custom-dap' } } },
        },
        lua = { filetypes = { 'lua' } },
      })
      -- `util.languages` read the languages when it loaded
      h.unload('util.languages')
      restores[#restores + 1] = function() h.unload('util.languages') end
      restores[#restores + 1] = h.stub(package.loaded, 'util.dap', {
        is_mapped = function(spec) return type(spec) == 'string' end,
        package = function(spec)
          if type(spec) == 'string' then return nil end
          return spec.mason.package
        end,
      })
      restores[#restores + 1] = h.stub(package.loaded, 'util.lazy_install', {
        on_filetype = function(filetypes, handler)
          table.insert(handlers, { filetypes = filetypes, handler = handler })
        end,
        install_once = function(package) table.insert(installed, package) end,
      })
      mason = spec('jay-babu/mason-nvim-dap.nvim')
    end)

    it('installs the adapters of a language with its first buffer', function()
      DyNeo.enabled_languages = { 'sh', 'lua' }
      mason.init()
      assert.are.equal(1, #handlers)
      assert.are.same({ 'sh', 'bash' }, handlers[1].filetypes)
      assert.are.same({}, installed)
      handlers[1].handler()
      -- The adapter mason-nvim-dap knows by name is left to it
      assert.are.same({ 'custom-dap' }, installed)
    end)

    it('installs nothing for a disabled language', function()
      DyNeo.enabled_languages = { 'lua' }
      mason.init()
      assert.are.same({}, handlers)
    end)

    it('installs the adapters of the bundle up front', function()
      DyNeo.bundle_languages = { 'sh' }
      local opts = {}
      mason.opts(nil, opts)
      assert.is_false(opts.automatic_installation)
      assert.are.same({}, opts.handlers)
      assert.are.same({ 'bash' }, opts.ensure_installed)
      assert.are.same({ 'custom-dap' }, installed)
    end)

    it('keeps what other specs put in the options', function()
      local opts = { handlers = { x = 1 }, ensure_installed = { 'delve' } }
      mason.opts(nil, opts)
      assert.are.same({ x = 1 }, opts.handlers)
      assert.are.same({ 'delve' }, opts.ensure_installed)
    end)

    it('loads its commands when typed first', function()
      local commands = {}
      restores[#restores + 1] =
        h.stub(package.loaded, 'mason-nvim-dap.api.command', commands)
      assert.has_no.errors(mason.config)
    end)
  end)

  it('names the DAP completion source', function()
    DyNeo.completion_sources = { lsp = 'LSP' }
    spec('rcarriga/cmp-dap').init()
    assert.are.same(
      { lsp = 'LSP', dap = '「DAP」' },
      DyNeo.completion_sources
    )
  end)
end)
