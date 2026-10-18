local h = require('helpers')

describe('plugins.lang.clojure', function()
  local restores, specs, globals

  --- The spec of `name` among those `plugins.lang.clojure` returns
  ---@param name string
  ---@return table
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    restores = {}
    globals = {}
    for _, name in ipairs({
      'conjure#filetypes',
      'conjure#mapping#doc_word',
      'conjure#mapping#def_word',
    }) do
      globals[name] = vim.g[name]
    end
    specs = dofile(h.root .. '/lua/plugins/lang/clojure.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    for name, value in pairs(globals) do
      vim.g[name] = value
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_conjure_log')
    vim.cmd('silent! %bwipeout!')
  end)

  it('keeps Conjure to Clojure and its doc keys off K and gd', function()
    spec('Olical/conjure').init()
    assert.same({ 'clojure' }, vim.g['conjure#filetypes'])
    assert.are.equal('K', vim.g['conjure#mapping#doc_word'])
    assert.are.equal('gd', vim.g['conjure#mapping#def_word'])

    local started = false
    table.insert(
      restores,
      h.stub(package.loaded, 'conjure.main', {
        main = function() started = true end,
      })
    )
    spec('Olical/conjure').config()
    assert.is_true(started)
  end)

  it('walks the evaluations of the log without diagnostics', function()
    spec('Olical/conjure').init()
    local log = h.buffer({ name = 'conjure-log-1.cljc' })
    vim.api.nvim_set_current_buf(log)
    assert.is_false(vim.diagnostic.is_enabled({ bufnr = log }))
    local prev = vim.fn.maparg('[c', 'n', false, true)
    assert.are.equal(1, prev.buffer)
    assert.matches("'bw'", prev.rhs)
    assert.matches("'w'", vim.fn.maparg(']c', 'x', false, true).rhs)

    local other = h.buffer({ name = 'core.clj' })
    vim.api.nvim_set_current_buf(other)
    assert.is_true(vim.diagnostic.is_enabled({ bufnr = other }))
    assert.same({}, vim.fn.maparg('[c', 'n', false, true))
  end)

  it('completes from the REPL', function()
    spec('PaterJason/cmp-conjure').init()
    assert.are.equal('「REPL」', DyNeo.completion_sources.conjure)
    local sources = spec('blink.cmp').opts.sources
    assert.same({ 'conjure' }, sources.compat)
    assert.is_true(vim.list_contains(sources.per_filetype.clojure, 'conjure'))
  end)
end)
