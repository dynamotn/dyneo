local h = require('helpers')

describe('plugins.executor.testing: vim-test in zellij', function()
  local restores, started

  before_each(function()
    h.globals()
    started = {}
    restores = {
      h.stub(DyNeo, 'test_strategy', 'zellij'),
      h.stub(vim.fn, 'jobstart', function(argv, opts)
        table.insert(started, { argv = argv, opts = opts })
        return 1
      end),
    }
    -- `neotest` lists vim-test as a dependency of its vim-test adapter
    local spec
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/testing.lua'))
    do
      if plugin[1] == 'nvim-neotest/neotest' then
        spec = plugin.dependencies[2].dependencies
      end
    end
    spec.config(nil, {})
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.g['test#custom_strategies'] = nil
    vim.g['test#strategy'] = nil
  end)

  it('hands the command to the shell as it is, without waiting', function()
    local cmd = 'pytest test_a.py -k "x % y" # !note'
    vim.fn.call(vim.g['test#custom_strategies'].zellij, { cmd })
    assert.are.equal(1, #started)
    local argv = started[1].argv
    assert.are.equal('zellij', argv[1])
    assert.are.equal(cmd, argv[#argv])
    assert.are.equal(vim.o.shell, argv[vim.fn.index(argv, '--') + 2])
    assert.is_true(started[1].opts.detach)
  end)
end)
