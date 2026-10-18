local h = require('helpers')

-- The settings `ftplugin/` gives a filetype, applied once the buffer gets it
describe('ftplugin', function()
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  --- A listed buffer of `ft`, shown in the current window, so that both
  --- buffer and window options are the ftplugin's to set
  ---@param ft string
  ---@return integer bufnr
  local function open(ft)
    local bufnr = h.buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = ft
    return bufnr
  end

  it('keeps a man page out of the buffer list', function()
    local bufnr = open('man')
    assert.is_false(vim.bo[bufnr].buflisted)
  end)

  for _, ft in ipairs({ 'json', 'jsonc', 'json5' }) do
    it('shows the quotes of ' .. ft, function()
      vim.o.conceallevel = 2
      open(ft)
      assert.are.equal(0, vim.wo.conceallevel)
    end)
  end

  for _, ft in ipairs({ 'plaintex', 'typst', 'gitcommit', 'markdown' }) do
    it('wraps and spells ' .. ft, function()
      vim.o.wrap = false
      vim.o.spell = false
      open(ft)
      assert.is_true(vim.wo.wrap)
      assert.is_true(vim.wo.spell)
    end)
  end

  it('wraps the Mason window', function()
    vim.o.wrap = false
    open('mason')
    assert.is_true(vim.wo.wrap)
  end)

  it('indents a Dockerfile by four', function()
    local bufnr = open('dockerfile')
    assert.are.equal(4, vim.bo[bufnr].shiftwidth)
    assert.are.equal(4, vim.bo[bufnr].softtabstop)
  end)

  it('leaves a markdown float alone', function()
    local bufnr = h.buffer()
    vim.bo[bufnr].buftype = 'nofile'
    vim.api.nvim_set_current_buf(bufnr)
    vim.o.wrap = false
    vim.bo[bufnr].filetype = 'markdown'
    assert.is_false(vim.wo.wrap)
    assert.same({}, vim.fn.maparg('<localleader>r', 'n', false, true))
  end)

  for _, ft in ipairs({
    'Avante',
    'AvanteInput',
    'AvanteSelectedCode',
    'AvanteSelectedFiles',
    'AvanteTodos',
  }) do
    it('styles the ' .. ft .. ' panel like the other panels', function()
      vim.o.scrolloff = 5
      vim.o.colorcolumn = '80'
      local bufnr = open(ft)
      assert.is_true(vim.b[bufnr].dy_panel)
      assert.are.equal(0, vim.wo.scrolloff)
      assert.are.equal('', vim.wo.colorcolumn)
    end)
  end
end)
