local h = require('helpers')

describe('plugins.toolbox.session', function()
  local restore, calls, persistence

  before_each(function()
    h.globals()
    calls = {}
    restore = h.stub(
      package.loaded,
      'persistence',
      setmetatable({}, {
        __index = function(_, name)
          return function(opts) table.insert(calls, { name, opts }) end
        end,
      })
    )
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/session.lua')) do
      if spec[1] == 'folke/persistence.nvim' then persistence = spec end
    end
  end)
  after_each(function() restore() end)

  it('restores, selects and stops the session from the quit group', function()
    assert.are.equal('BufReadPre', persistence.event)
    for _, key in ipairs(persistence.keys) do
      key[2]()
    end
    assert.same({
      { 'load' },
      { 'select' },
      { 'load', { last = true } },
      { 'stop' },
    }, calls)
    assert.are.equal('<leader>qd', persistence.keys[4][1])
  end)
end)
