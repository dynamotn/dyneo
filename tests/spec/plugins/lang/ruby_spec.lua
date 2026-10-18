local h = require('helpers')

describe('plugins.lang.ruby', function()
  before_each(function() h.globals() end)

  it('sets the Ruby debugger up along with nvim-dap', function()
    local set_up = false
    local restore = h.stub(package.loaded, 'dap-ruby', {
      setup = function() set_up = true end,
    })
    local specs = dofile(h.root .. '/lua/plugins/lang/ruby.lua')
    assert.are.equal('suketa/nvim-dap-ruby', specs[1].dependencies[1])
    assert.is_nil(specs[1].dependencies.ft)
    specs[1].dependencies.config()
    restore()
    assert.is_true(set_up)
    assert.same({ 'ruby' }, specs[2].dependencies.ft)
    assert.same({}, specs[2].opts.adapters['neotest-rspec'])
  end)
end)
