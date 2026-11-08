local h = require('helpers')

describe('plugins.lang.c_sharp', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.c_sharp` returns
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
    specs = dofile(h.root .. '/lua/plugins/lang/c_sharp.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('leaves the language server to roslyn_ls as lspconfig sets it', function()
    -- Roslyn decompiles a definition itself; no extension takes over `gd`
    assert.has_error(function() spec('Hoffs/omnisharp-extended-lsp.nvim') end)
    assert.has_error(function() spec('neovim/nvim-lspconfig') end)
    assert.is_true(
      vim.list_contains(
        require('config.languages').c_sharp.lsp_servers,
        'roslyn_ls'
      )
    )
  end)

  it('debugs through netcoredbg, asking for the dll', function()
    local dap = { adapters = {}, configurations = {} }
    table.insert(restores, h.stub(package.loaded, 'dap', dap))
    table.insert(
      restores,
      h.stub(
        vim.fn,
        'input',
        function(prompt, default) return prompt .. default end
      )
    )
    spec('mfussenegger/nvim-dap').opts()
    assert.are.equal('netcoredbg', dap.adapters.netcoredbg.command)
    local launch = dap.configurations.cs[1]
    assert.are.equal('netcoredbg', launch.type)
    assert.are.equal(
      'Path to dll: ' .. vim.fn.getcwd() .. '/',
      launch.program()
    )

    -- What is registered already stays
    local adapter, configs = dap.adapters.netcoredbg, dap.configurations.cs
    spec('mfussenegger/nvim-dap').opts()
    assert.are.equal(adapter, dap.adapters.netcoredbg)
    assert.are.equal(configs, dap.configurations.cs)
  end)

  it('keeps mason-nvim-dap from adding a second adapter', function()
    local handlers = spec('jay-babu/mason-nvim-dap.nvim').opts.handlers
    assert.is_nil(handlers.coreclr())
    assert.same(
      {},
      spec('nvim-neotest/neotest').opts.adapters['neotest-vstest']
    )
  end)
end)
