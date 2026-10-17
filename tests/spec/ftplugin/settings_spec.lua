local h = require('helpers')

-- The settings `ftplugin/` gives a filetype, applied once the buffer gets it
describe('ftplugin', function()
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  it('keeps a man page out of the buffer list', function()
    local bufnr = h.buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'man'
    assert.is_false(vim.bo[bufnr].buflisted)
  end)

  for _, ft in ipairs({ 'json', 'jsonc', 'json5' }) do
    it('shows the quotes of ' .. ft, function()
      vim.o.conceallevel = 2
      vim.api.nvim_set_current_buf(h.buffer())
      vim.bo.filetype = ft
      assert.are.equal(0, vim.wo.conceallevel)
    end)
  end
end)
