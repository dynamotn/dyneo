local h = require('helpers')

describe('plugins.lang.go', function()
  local restores, specs, hook

  --- The spec of `name` among those `plugins.lang.go` returns
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
    restores = {
      h.stub(_G, 'Snacks', {
        util = {
          lsp = {
            on = function(filter, fn)
              assert.are.equal('gopls', filter.name)
              hook = fn
            end,
          },
        },
      }),
    }
    specs = dofile(h.root .. '/lua/plugins/lang/go.lua')
    spec('neovim/nvim-lspconfig').opts.setup.gopls()
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('advertises semantic tokens on behalf of gopls', function()
    local client = {
      server_capabilities = {},
      capabilities = {
        textDocument = {
          semanticTokens = {
            tokenTypes = { 'type' },
            tokenModifiers = { 'static' },
          },
        },
      },
    }
    hook(nil, client)
    assert.same({
      full = true,
      range = true,
      legend = { tokenTypes = { 'type' }, tokenModifiers = { 'static' } },
    }, client.server_capabilities.semanticTokensProvider)
  end)

  it(
    'leaves a gopls that provides them, and a client that asks none',
    function()
      local provider = { full = true }
      local client = {
        server_capabilities = { semanticTokensProvider = provider },
        capabilities = {},
      }
      hook(nil, client)
      assert.are.equal(
        provider,
        client.server_capabilities.semanticTokensProvider
      )
      client = { server_capabilities = {}, capabilities = {} }
      hook(nil, client)
      assert.is_nil(client.server_capabilities.semanticTokensProvider)
    end
  )

  it('debugs through nvim-dap-go alone', function()
    assert.same(
      { 'leoluz/nvim-dap-go', opts = {} },
      spec('mfussenegger/nvim-dap').dependencies
    )
    assert.is_nil(spec('jay-babu/mason-nvim-dap.nvim').opts.handlers.delve())
    assert.are.equal(
      'dap-go',
      spec('nvim-neotest/neotest').opts.adapters['neotest-golang'].dap_mode
    )
  end)
end)
