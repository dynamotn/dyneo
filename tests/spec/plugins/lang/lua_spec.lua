local h = require('helpers')

describe('plugins.lang.lua', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.lua` returns
  ---@param name string
  ---@return table
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/lang/lua.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('completes the Neovim API through lazydev', function()
    spec('folke/lazydev.nvim').init()
    assert.are.equal('「VIM」', DyNeo.completion_sources.lazydev)
    local sources = spec('blink.cmp').opts.sources
    assert.are.equal(100, sources.providers.lazydev.score_offset)
    assert.is_true(vim.list_contains(sources.per_filetype.lua, 'lazydev'))
    assert.is_true(
      spec('neovim/nvim-lspconfig').opts.servers.lua_ls.settings.Lua.hint.enable
    )
  end)

  it('launches the debug server and attaches to it', function()
    local launched
    table.insert(
      restores,
      h.stub(package.loaded, 'osv', {
        launch = function(opts) launched = opts end,
      })
    )
    local key = spec('jbyuki/one-small-step-for-vimkind').keys[1]
    assert.are.equal('<leader>dn', key[1])
    key[2]()
    assert.same({ port = 8086 }, launched)

    local dap = { adapters = {}, configurations = {} }
    table.insert(restores, h.stub(package.loaded, 'dap', dap))
    spec('mfussenegger/nvim-dap').opts()
    assert.are.equal(8086, dap.configurations.lua[1].port)
    assert.are.equal('nlua', dap.configurations.lua[1].type)
    local adapter
    dap.adapters.nlua(function(a) adapter = a end, {})
    assert.same({ type = 'server', host = '127.0.0.1', port = 8086 }, adapter)
    dap.adapters.nlua(function(a) adapter = a end, { host = 'dev', port = 1 })
    assert.same({ type = 'server', host = 'dev', port = 1 }, adapter)
  end)

  it('tests with plenary through the minimal init of the project', function()
    local neotest = spec('nvim-neotest/neotest')
    assert.same({ 'lua' }, neotest.dependencies.ft)
    assert.same({}, neotest.opts.adapters['util.neotest_plenary'])
  end)
end)
