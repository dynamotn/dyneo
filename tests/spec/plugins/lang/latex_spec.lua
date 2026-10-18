local h = require('helpers')

describe('plugins.lang.latex', function()
  before_each(function() h.globals() end)

  it('checks the grammar of LaTeX alone, as LaTeX', function()
    local specs = dofile(h.root .. '/lua/plugins/lang/latex.lua')
    assert.are.equal('latex', vim.g.tex_flavor)
    assert.same(
      { 'tex', 'plaintex', 'bib' },
      specs[1].opts.servers.ltex_plus.filetypes
    )
  end)
end)
