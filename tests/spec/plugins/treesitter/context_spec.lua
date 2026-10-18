local h = require('helpers')

describe('plugins.treesitter.context', function()
  local restores, tsc, toggles

  before_each(function()
    h.globals()
    toggles = {}
    tsc = {
      state = true,
      enabled = function() return tsc.state end,
      enable = function() tsc.state = true end,
      disable = function() tsc.state = false end,
      go_to_context = function(count) tsc.went = count end,
    }
    restores = {
      h.stub(package.loaded, 'treesitter-context', tsc),
      h.stub(_G, 'Snacks', {
        toggle = function(opts)
          table.insert(toggles, opts)
          return {
            map = function(_, lhs) opts.mapped = lhs end,
          }
        end,
      }),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  ---@return table
  local function spec()
    return dofile(h.root .. '/lua/plugins/treesitter/context.lua')[1]
  end

  it('toggles the context with <leader>ut', function()
    local opts = spec().opts()
    assert.same({ mode = 'cursor', max_lines = 3 }, opts)
    local toggle = toggles[1]
    assert.equals('Treesitter Context', toggle.name)
    assert.equals('<leader>ut', toggle.mapped)
    assert.is_true(toggle.get())
    toggle.set(false)
    assert.is_false(tsc.state)
    toggle.set(true)
    assert.is_true(tsc.state)
  end)

  it('goes to the context of the count', function()
    spec().keys[1][2]()
    assert.equals(vim.v.count1, tsc.went)
  end)
end)
