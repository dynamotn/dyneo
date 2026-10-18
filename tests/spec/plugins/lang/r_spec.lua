local h = require('helpers')

describe('plugins.lang.r', function()
  local restores, spec

  before_each(function()
    h.globals()
    restores = { h.stub(vim.g, 'R_filetypes', nil) }
    for _, s in ipairs(dofile(h.root .. '/lua/plugins/lang/r.lua')) do
      if s[1] == 'R-nvim/R.nvim' then spec = s end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.g.rout_follow_colorscheme = nil
    vim.cmd('silent! %bwipeout!')
  end)

  it('loads R.nvim on the filetypes it is told to serve', function()
    assert.is_not_false(spec.lazy)
    spec.init()
    assert.is_true(vim.list_contains(spec.ft, 'r'))
    assert.is_false(vim.list_contains(spec.ft, 'quarto'))
    assert.same(spec.ft, vim.g.R_filetypes)
  end)

  it('only starts where R can be asked', function()
    local executables = {}
    table.insert(
      restores,
      h.stub(
        vim.fn,
        'executable',
        function(name) return vim.list_contains(executables, name) and 1 or 0 end
      )
    )
    assert.is_false(spec.cond())
    executables = { 'R' }
    assert.is_true(spec.cond())
  end)

  it('sends lines to R with Enter and groups its local leader keys', function()
    local groups
    table.insert(
      restores,
      h.stub(package.loaded, 'which-key', {
        add = function(spec_) groups = spec_ end,
      })
    )
    local bufnr = h.buffer({ name = 'a.R' })
    vim.api.nvim_set_current_buf(bufnr)
    spec.opts.hook.on_filetype()
    local normal = vim.fn.maparg('<Enter>', 'n', false, true)
    assert.are.equal(1, normal.buffer)
    assert.are.equal('<Plug>RDSendLine', normal.rhs)
    local visual = vim.fn.maparg('<Enter>', 'x', false, true)
    assert.are.equal('<Plug>RSendSelection', visual.rhs)
    assert.is_true(groups.buffer)
    assert.same({ 'n', 'x' }, groups.mode)
    assert.are.equal('<localleader>a', groups[1][1])
    assert.are.equal('view', groups[#groups].group)
  end)

  it('sets R.nvim up with the PDF viewer of the system', function()
    local setup_opts
    local generic = { open = function() end }
    table.insert(
      restores,
      h.stub(package.loaded, 'r', {
        setup = function(opts) setup_opts = opts end,
      })
    )
    table.insert(restores, h.stub(package.loaded, 'r.pdf.generic', generic))
    spec.config(nil, spec.opts)
    assert.is_true(vim.g.rout_follow_colorscheme)
    assert.are.equal(spec.opts, setup_opts)
    assert.are.equal(vim.ui.open, generic.open)
  end)
end)
