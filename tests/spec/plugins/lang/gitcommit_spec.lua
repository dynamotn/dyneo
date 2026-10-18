local h = require('helpers')

describe('plugins.lang.gitcommit', function()
  before_each(function() h.globals() end)

  it('checks the grammar and completes issues of a commit message', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/gitcommit.lua')
    assert.same({}, specs[1].opts.servers.harper_ls)
    assert.are.equal('petertriho/cmp-git', specs[2][1])
    assert.same({ 'gitcommit' }, specs[2].ft)
    specs[2].init()
    assert.are.equal('「GIT」', DyNeo.completion_sources.git)
    local sources = specs[3].opts.sources
    assert.same({ 'git' }, sources.compat)
    assert.is_true(vim.list_contains(sources.per_filetype.gitcommit, 'git'))
  end)
end)
