local h = require('helpers')

describe('plugins.lang.fish', function()
  before_each(function() h.globals() end)

  it(
    'completes fish through its own source, loaded with a fish file',
    function()
      local specs = dofile(h.root .. '/lua/plugins/lang/fish.lua')
      assert.are.equal('mtoohey31/cmp-fish', specs[1][1])
      assert.same({ 'fish' }, specs[1].ft)
      specs[1].init()
      assert.are.equal('「FISH」', DyNeo.completion_sources.fish)
      local sources = specs[2].opts.sources
      assert.same({ 'fish' }, sources.compat)
      assert.is_true(vim.list_contains(sources.per_filetype.fish, 'fish'))
    end
  )
end)
