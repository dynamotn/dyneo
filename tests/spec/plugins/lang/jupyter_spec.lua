local h = require('helpers')

describe('plugins.lang.jupyter', function()
  local restore, dir, cleanup, spec

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    spec = dofile(h.root .. '/lua/plugins/lang/jupyter.lua')[1]
  end)
  after_each(function()
    if restore then restore() end
    restore = nil
    cleanup()
  end)

  it("runs the plugin's own installer from its checkout", function()
    h.write(dir .. '/lua/jupynvim/install.lua', {
      'return { run = function(plugin) plugin.installed = true end }',
    })
    local plugin = { dir = dir }
    spec.build(plugin)
    assert.is_true(plugin.installed)
  end)

  it('sets jupynvim up and reopens a notebook on demand', function()
    local set_up = false
    restore = h.stub(package.loaded, 'jupynvim', {
      setup = function() set_up = true end,
    })
    spec.config()
    assert.is_true(set_up)
    assert.same({ 'ipynb' }, spec.ft)
    assert.are.equal('<leader>cj', spec.keys[1][1])
    assert.same({ 'ipynb' }, spec.keys[1].ft)
  end)
end)
