local h = require('helpers')

describe('plugins.lang.php', function()
  before_each(function() h.globals() end)

  it('tests with PHPUnit, loaded with a PHP file', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/php.lua')
    assert.are.equal(1, #specs)
    assert.are.equal('olimorris/neotest-phpunit', specs[1].dependencies[1])
    assert.same({ 'php' }, specs[1].dependencies.ft)
    assert.same({}, specs[1].opts.adapters['neotest-phpunit'])
  end)
end)
