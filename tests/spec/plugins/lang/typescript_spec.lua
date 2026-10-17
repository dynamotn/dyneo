local h = require('helpers')

describe('plugins.lang.typescript', function()
  local restores, hooks

  before_each(function()
    h.globals()
    hooks = 0
    restores = {
      h.stub(_G, 'Snacks', {
        util = { lsp = { on = function() hooks = hooks + 1 end } },
      }),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('hooks vtsls once, however many languages name it', function()
    local setup
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/typescript.lua')) do
      if spec[1] == 'neovim/nvim-lspconfig' and type(spec.opts) == 'table' then
        setup = spec.opts.setup.vtsls
      end
    end
    local opts = { settings = { typescript = { suggest = { x = true } } } }
    for _ = 1, 4 do
      assert.is_nil((setup('vtsls', opts)))
    end
    assert.are.equal(1, hooks)
    assert.same({ suggest = { x = true } }, opts.settings.javascript)
  end)
end)
