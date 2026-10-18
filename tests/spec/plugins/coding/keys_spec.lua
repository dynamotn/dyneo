local h = require('helpers')

describe('plugins.coding.keys: which-key', function()
  local spec, calls, restores

  before_each(function()
    calls = {}
    restores = {
      h.stub(package.loaded, 'which-key', {
        show = function(opts) table.insert(calls, opts) end,
      }),
      h.stub(package.loaded, 'which-key.extras', {
        expand = {
          buf = function() return 'buffers' end,
          win = function() return 'windows' end,
        },
      }),
    }
    spec = dofile(h.root .. '/lua/plugins/coding/keys.lua')[1]
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('expands the buffer and window groups through its extras', function()
    local expanded = {}
    for _, item in ipairs(spec.opts.spec[1]) do
      if item.expand then expanded[item[1]] = item.expand() end
    end
    assert.same(
      { ['<leader>b'] = 'buffers', ['<leader>w'] = 'windows' },
      expanded
    )
  end)

  it('shows the buffer keys, and the window keys as a hydra', function()
    for _, key in ipairs(spec.keys) do
      key[2]()
    end
    assert.same({ { global = false }, { keys = '<c-w>', loop = true } }, calls)
  end)
end)
