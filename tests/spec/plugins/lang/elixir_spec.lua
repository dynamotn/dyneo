local h = require('helpers')

describe('plugins.lang.elixir', function()
  local restore, dap, specs

  before_each(function()
    h.globals()
    dap = { adapters = {}, configurations = {} }
    restore = h.stub(package.loaded, 'dap', dap)
    specs = dofile(h.root .. '/lua/plugins/lang/elixir.lua')
  end)
  after_each(function() restore() end)

  it('runs the tests under the ElixirLS debugger as mix tasks', function()
    specs[1].opts()
    assert.are.equal('elixir-ls-debugger', dap.adapters.mix_task.command)
    local all, file = unpack(dap.configurations.elixir)
    assert.are.equal('mix test', all.name)
    assert.same({ '--trace' }, all.taskArgs)
    assert.are.equal('mix test (file)', file.name)
    assert.same({ '${file}', '--trace' }, file.taskArgs)
    for _, config in ipairs({ all, file }) do
      assert.are.equal('mix_task', config.type)
      assert.are.equal('test', config.task)
      assert.is_true(config.startApps)
    end
  end)

  it('tests through neotest-elixir', function()
    assert.same({}, specs[2].opts.adapters['neotest-elixir'])
    assert.same({ 'elixir' }, specs[2].dependencies.ft)
  end)
end)
