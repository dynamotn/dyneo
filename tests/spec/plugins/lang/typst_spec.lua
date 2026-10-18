local h = require('helpers')

describe('plugins.lang.typst', function()
  local restore, specs

  before_each(function()
    h.globals()
    specs = dofile(h.root .. '/lua/plugins/lang/typst.lua')
  end)
  after_each(function()
    if restore then restore() end
    restore = nil
    vim.cmd('silent! %bwipeout!')
  end)

  it('pins the main file of a multi-file document', function()
    local executed
    restore = h.stub(
      require('util.lsp'),
      'execute',
      function(opts) executed = opts end
    )
    local bufnr = h.buffer({ name = '/tmp/dy/main.typ' })
    vim.api.nvim_set_current_buf(bufnr)
    local key = specs[1].opts.servers.tinymist.keys[1]
    assert.are.equal('<leader>cP', key[1])
    assert.same({ 'typst' }, key.ft)
    key[2]()
    assert.same({
      command = 'tinymist.pinMain',
      arguments = { vim.api.nvim_buf_get_name(bufnr) },
    }, executed)
    assert.are.equal(
      'typstyle',
      specs[1].opts.servers.tinymist.settings.formatterMode
    )
  end)

  it('previews through tinymist and completes typst', function()
    assert.are.equal('tinymist', specs[2].opts.dependencies_bin.tinymist)
    assert.are.equal('<cmd>TypstPreviewToggle<cr>', specs[2].keys[1][2])
    assert.same({ '// %s', '/* %s */' }, specs[3].opts.lang.typst)
    assert.is_true(
      vim.list_contains(specs[4].opts.sources.per_filetype.typst, 'lsp')
    )
  end)
end)
