local h = require('helpers')

describe('plugins.executor.linting', function()
  local spec, lint, linted, restores

  before_each(function()
    h.globals()
    linted = {}
    lint = {
      linters = {
        -- On every machine: what runs it is all the filter asks
        present = { cmd = 'sh' },
        absent = { cmd = 'dy-no-such-linter' },
        declined = { cmd = 'sh', condition = function() return false end },
        compiler = {},
      },
      linters_by_ft = {},
      try_lint = function(names) table.insert(linted, names) end,
      _resolve_linter_by_ft = function(ft) return lint.linters_by_ft[ft] or {} end,
    }
    restores = {
      h.stub(package.loaded, 'lint', lint),
      -- Reads nvim-lint's own parsers, which the stub has none of
      h.stub(package.loaded, 'util.lint_code', { setup = function() end }),
    }
    for _, plugin in
      ipairs(dofile(h.root .. '/lua/plugins/executor/linting.lua'))
    do
      if plugin[1] == 'mfussenegger/nvim-lint' then spec = plugin end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  --- What reached `try_lint` from the debounced runner: vale runs from a
  --- `BufWritePost` of its own, where this machine has it and a config
  local function runs()
    return vim.tbl_filter(
      function(names) return not vim.list_contains(names, 'vale') end,
      linted
    )
  end

  --- Set nvim-lint up, open a buffer of a filetype naming every linter, run
  --- `before`, then write it
  ---@param before? fun()
  local function lint_on_write(before)
    local opts = spec.opts(nil, {})
    opts.events = { 'BufWritePost' }
    opts.linters_by_ft =
      { dytext = { 'present', 'absent', 'declined', 'compiler' } }
    spec.config(nil, opts)
    local bufnr = h.buffer({ name = vim.fn.tempname() .. '.txt' })
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'dytext'
    if before then before() end
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
    vim.wait(500, function() return #runs() > 0 end, 10)
  end

  it('runs only the linters that can run on the buffer', function()
    lint_on_write()
    assert.same({ { 'present' } }, runs())
  end)

  it('lints nothing while the editor quits, again once it stays', function()
    lint_on_write(function() vim.api.nvim_exec_autocmds('QuitPre', {}) end)
    assert.same({}, runs())
    -- A window closed, not the editor: back to waiting for input
    vim.api.nvim_exec_autocmds('SafeState', {})
    vim.api.nvim_exec_autocmds('BufWritePost', { buffer = 0 })
    assert.is_true(vim.wait(500, function() return #runs() > 0 end, 10))
  end)
end)
