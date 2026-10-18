local h = require('helpers')

describe('plugins.lang.gitrebase', function()
  before_each(function() h.globals() end)

  it('completes commits of a rebase through the git source', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/gitrebase.lua')
    assert.are.equal('petertriho/cmp-git', specs[1][1])
    assert.same({ 'gitrebase' }, specs[1].ft)
    local sources = specs[2].opts.sources
    assert.same({ 'git' }, sources.compat)
    assert.is_true(vim.list_contains(sources.per_filetype.gitrebase, 'git'))
  end)
end)
