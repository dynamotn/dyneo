local h = require('helpers')

describe('plugins.lang.zig', function()
  local restores, dap, specs

  before_each(function()
    h.globals()
    dap = { adapters = {}, configurations = {} }
    restores = {
      h.stub(package.loaded, 'dap', dap),
      h.stub(package.loaded, 'dap.utils', { pick_process = 'pick' }),
      h.stub(vim.fn, 'input', function(_, default) return default end),
    }
    specs = dofile(h.root .. '/lua/plugins/lang/zig.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('debugs what zig build leaves in zig-out through codelldb', function()
    specs[1].opts()
    assert.are.equal('codelldb', dap.adapters.codelldb.executable.command)
    local launch, attach = unpack(dap.configurations.zig)
    assert.are.equal('codelldb', launch.type)
    assert.are.equal(vim.fn.getcwd() .. '/zig-out/bin/', launch.program())
    assert.are.equal('pick', attach.pid)
    assert.is_nil(specs[2].opts.handlers.codelldb())
    assert.same({}, specs[3].opts.adapters['neotest-zig'])
  end)
end)
