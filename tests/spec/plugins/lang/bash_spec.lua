local h = require('helpers')

describe('plugins.lang.bash', function()
  before_each(function() h.globals() end)

  it('indexes the scripts below the root and leaves shellcheck out', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/bash.lua')
    local bashls = specs[1].opts.servers.bashls
    assert.are.equal(
      '**/*@(.sh|.inc|.bash|.command)',
      bashls.settings.bashIde.globPattern
    )
    assert.are.equal('', bashls.settings.bashIde.shellcheckPath)
  end)

  it('contributes nothing while Bash is off', function()
    DyNeo.enabled_languages = { 'lua' }
    assert.same({}, dofile(h.root .. '/lua/plugins/lang/bash.lua'))
  end)
end)
