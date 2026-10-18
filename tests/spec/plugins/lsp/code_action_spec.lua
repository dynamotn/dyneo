local h = require('helpers')

describe('plugins.lsp.code_action', function()
  local specs

  before_each(
    function() specs = dofile(h.root .. '/lua/plugins/lsp/code_action.lua') end
  )

  it('picks code actions through snacks', function()
    assert.are.equal('rachartier/tiny-code-action.nvim', specs[1][1])
    assert.are.equal('snacks', specs[1].opts.picker)
  end)

  it('replaces the code action key of every server', function()
    local opts = {}
    specs[2].opts(nil, opts)
    local key = opts.servers['*'].keys[1]
    assert.are.equal('<leader>ca', key[1])
    assert.are.equal('codeAction', key.has)
    assert.same({ 'n', 'x' }, key.mode)
    local called = false
    local restore = h.stub(package.loaded, 'tiny-code-action', {
      code_action = function() called = true end,
    })
    key[2]()
    restore()
    assert.is_true(called)
  end)
end)
