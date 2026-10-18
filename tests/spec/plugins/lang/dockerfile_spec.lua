local h = require('helpers')

describe('plugins.lang.dockerfile', function()
  before_each(function() h.globals() end)

  it(
    'brings the Docker adapter along with nvim-dap, not with a file',
    function()
      local specs = dofile(h.root .. '/lua/plugins/lang/dockerfile.lua')
      assert.are.equal('mfussenegger/nvim-dap', specs[1][1])
      assert.are.equal('docker/nvim-dap-docker', specs[1].dependencies[1])
      assert.is_nil(specs[1].dependencies.ft)
      assert.same({}, specs[1].dependencies.opts)
    end
  )

  it('contributes nothing while Dockerfiles are off', function()
    DyNeo.enabled_languages = { 'lua' }
    assert.same({}, dofile(h.root .. '/lua/plugins/lang/dockerfile.lua'))
  end)
end)
