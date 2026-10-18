local h = require('helpers')

describe('plugins.integration.game', function()
  before_each(function() h.globals() end)

  it('leaves leetcode off unless asked for', function()
    local specs = dofile(h.root .. '/lua/plugins/integration/game.lua')
    assert.equals('kawre/leetcode.nvim', specs[1][1])
    assert.is_false(specs[1].enabled)
    DyNeo.enabled_plugins.leetcode = true
    assert.is_true(
      dofile(h.root .. '/lua/plugins/integration/game.lua')[1].enabled
    )
  end)
end)
