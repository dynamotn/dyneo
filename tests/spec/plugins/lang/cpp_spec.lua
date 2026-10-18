local h = require('helpers')

describe('plugins.lang.cpp', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.cpp` returns
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
    specs = dofile(h.root .. '/lua/plugins/lang/cpp.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('starts one clangd per repository, not per Makefile', function()
    local clangd = spec('neovim/nvim-lspconfig').opts.servers.clangd
    assert.are.equal('.git', clangd.root_markers[3])
    assert.is_true(vim.list_contains(clangd.root_markers[4], 'Makefile'))
    assert.are.equal('clangd', clangd.cmd[1])
    assert.are.equal('<leader>ch', clangd.keys[1][1])
    assert.same({ 'c', 'cpp' }, clangd.keys[1].ft)
  end)

  it('debugs C and C++ through codelldb', function()
    local dap = { adapters = {}, configurations = {} }
    table.insert(restores, h.stub(package.loaded, 'dap', dap))
    table.insert(
      restores,
      h.stub(package.loaded, 'dap.utils', { pick_process = 'pick' })
    )
    spec('mfussenegger/nvim-dap').opts()
    assert.are.equal('codelldb', dap.adapters.codelldb.executable.command)
    for _, lang in ipairs({ 'c', 'cpp' }) do
      assert.are.equal('Launch file', dap.configurations[lang][1].name)
      assert.are.equal('pick', dap.configurations[lang][2].pid)
    end
    assert.is_nil(spec('jay-babu/mason-nvim-dap.nvim').opts.handlers.codelldb())
  end)

  it('tests with gtest only once the C++ parser is there', function()
    local has_parser = false
    table.insert(
      restores,
      h.stub(vim.treesitter.language, 'add', function(lang)
        assert.are.equal('cpp', lang)
        return has_parser or nil
      end)
    )
    local opts = {}
    spec('nvim-neotest/neotest').opts(nil, opts)
    assert.is_false(opts.adapters['neotest-gtest'])
    has_parser = true
    spec('nvim-neotest/neotest').opts(nil, opts)
    assert.same({}, opts.adapters['neotest-gtest'])
  end)
end)
