local h = require('helpers')

describe('plugins.lang.perl', function()
  local restore, dap

  before_each(function()
    h.globals()
    dap = { adapters = {}, configurations = {} }
    restore = h.stub(package.loaded, 'dap', dap)
  end)
  after_each(function() restore() end)

  it('registers the Perl debug adapter mason-nvim-dap does not know', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/perl.lua')
    specs[1].opts()
    assert.are.equal('perl-debug-adapter', dap.adapters.perl.command)
    assert.are.equal('executable', dap.adapters.perl.type)
    assert.are.equal(1, #dap.configurations.perl)
    assert.are.equal('${file}', dap.configurations.perl[1].program)
    assert.are.equal('perl', dap.configurations.perl[1].type)
  end)
end)
