local h = require('helpers')

describe('plugins.lang.quarto', function()
  local restore, calls, spec

  before_each(function()
    h.globals()
    calls = {}
    restore = h.stub(
      package.loaded,
      'quarto.runner',
      setmetatable({}, {
        __index = function(_, name)
          return function() table.insert(calls, name) end
        end,
      })
    )
    spec = dofile(h.root .. '/lua/plugins/lang/quarto.lua')[1]
  end)
  after_each(function() restore() end)

  it('runs the chunks of a Quarto document in iron', function()
    assert.are.equal('iron', spec.opts.codeRunner.default_method)
    assert.is_true(vim.list_contains(spec.dependencies, 'Vigemus/iron.nvim'))
    for _, key in ipairs(spec.keys) do
      -- Never on R Markdown, whose chunks R.nvim runs
      assert.are.equal('quarto', key.ft, key[1])
      if type(key[2]) == 'function' then key[2]() end
    end
    assert.same(
      { 'run_cell', 'run_above', 'run_all', 'run_line', 'run_range' },
      calls
    )
  end)

  it('goes where otter goes', function()
    DyNeo.enabled_plugins.otter = false
    DyNeo.used_full_plugins = false
    assert.is_false(dofile(h.root .. '/lua/plugins/lang/quarto.lua')[1].enabled)
    DyNeo.enabled_plugins.otter = true
    assert.is_true(dofile(h.root .. '/lua/plugins/lang/quarto.lua')[1].enabled)
  end)
end)
