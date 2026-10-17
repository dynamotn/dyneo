local h = require('helpers')

describe('lsp.sonarlint', function()
  local dir, cleanup, restores, asked, config

  before_each(function()
    dir, cleanup = h.tmpdir()
    asked = 0
    restores = {
      h.stub(vim.fn, 'stdpath', function() return dir end),
      h.stub(vim.fn, 'inputsecret', function()
        asked = asked + 1
        return 'secret-value'
      end),
      h.stub(vim, 'notify', function() end),
    }
    config = dofile(h.root .. '/lsp/sonarlint.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  local get_token = function(org)
    return config.handlers['sonarlint/getTokenForServer'](nil, { org })
  end

  it('keeps a token under the name of its organization', function()
    assert.are.equal('secret-value', get_token('my-org.eu'))
    assert.are.equal(1, asked)
    assert.are.equal(
      1,
      vim.fn.filereadable(dir .. '/sonarlint/tokens/my-org.eu')
    )
    -- Read back, not asked again
    assert.are.equal('secret-value', get_token('my-org.eu'))
    assert.are.equal(1, asked)
  end)

  it('refuses a name reaching outside the token folder', function()
    h.write(dir .. '/outside', { 'not-a-token' })
    for _, name in ipairs({ '../../outside', '..', 'a/b', '' }) do
      assert.is_nil(get_token(name), name)
    end
    assert.are.equal(0, asked)
    assert.same({}, vim.fn.readdir(dir .. '/sonarlint/tokens'))
  end)
end)
