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
    -- RSpec and Minitest, both loaded with a Ruby file
    assert.same(
      { 'olimorris/neotest-rspec', 'zidhuss/neotest-minitest' },
      vim.tbl_map(function(dep) return dep[1] end, specs[2].dependencies)
    )
    for _, dep in ipairs(specs[2].dependencies) do
      assert.same({ 'ruby' }, dep.ft)
    end
    assert.same({}, specs[2].opts.adapters['neotest-rspec'])
    assert.same({}, specs[2].opts.adapters['neotest-minitest'])
  end)
end)
