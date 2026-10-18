local h = require('helpers')

describe('plugins.lang.julia', function()
  before_each(function() h.globals() end)

  it('completes the LaTeX names of the symbols Julia is written in', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/julia.lua')
    assert.are.equal(
      'qualify',
      specs[1].opts.servers.julials.settings.julia.completionmode
    )
    assert.are.equal('kdheepak/cmp-latex-symbols', specs[2][1])
    assert.same({ 'julia' }, specs[2].ft)
    specs[2].init()
    assert.are.equal('「TEX」', DyNeo.completion_sources.latex_symbols)
    local sources = specs[3].opts.sources
    assert.same({ 'latex_symbols' }, sources.compat)
    assert.are.equal(0, sources.providers.latex_symbols.opts.strategy)
    assert.is_true(
      vim.list_contains(sources.per_filetype.julia, 'latex_symbols')
    )
  end)
end)
