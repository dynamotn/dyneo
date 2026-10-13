local h = require('helpers')

describe('plugins.executor.formatting', function()
  local by_ft

  ---@return table<string, any>
  local function load()
    local conform
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if spec[1] == 'stevearc/conform.nvim' then conform = spec end
    end
    return conform.opts(nil, {}).formatters_by_ft
  end

  before_each(function()
    h.globals()
    by_ft = load()
  end)

  ---@param ft string
  ---@return string[]
  local function common(ft)
    local bufnr = h.buffer({})
    vim.bo[bufnr].filetype = ft
    return by_ft['*'](bufnr)
  end

  it('leaves a filetype without a formatter to its language server', function()
    -- `formatting is left to the language server` in config.languages
    assert.same({ lsp_format = 'last' }, by_ft.astro)
    assert.same({ lsp_format = 'last' }, by_ft._)
  end)

  it('keeps the blank lines of a filetype with a formatter', function()
    assert.is_false(vim.list_contains(common('python'), 'condense_blank_lines'))
    assert.is_true(vim.list_contains(common('conf'), 'condense_blank_lines'))
  end)

  it('keeps the blank lines while the formatter is not installed', function()
    local restore = h.stub(
      require('util.languages'),
      'is_available',
      function() return false end
    )
    local ok, result = pcall(load)
    restore()
    assert(ok, result)
    by_ft = result
    -- The server formats in place of the missing `ruff`
    assert.same({ lsp_format = 'last' }, by_ft.python)
    assert.is_false(vim.list_contains(common('python'), 'condense_blank_lines'))
  end)

  it('keeps the trailing spaces that mean something', function()
    assert.is_false(vim.list_contains(common('markdown'), 'trim_whitespace'))
    assert.same({}, common('diff'))
    assert.is_true(vim.list_contains(common('lua'), 'trim_whitespace'))
  end)

  it('condenses runs of blank lines to one, without sed', function()
    local conform
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/executor/formatting.lua'))
    do
      if spec[1] == 'stevearc/conform.nvim' then conform = spec end
    end
    local formatter = conform.opts(nil, {}).formatters.condense_blank_lines
    assert.is_nil(formatter.command)
    local result
    formatter.format(
      nil,
      nil,
      { 'a', '', '', '', 'b', '', 'c', ' ', '', '' },
      function(err, lines) result = { err = err, lines = lines } end
    )
    assert.is_nil(result.err)
    assert.same({ 'a', '', 'b', '', 'c', ' ', '' }, result.lines)
  end)
end)
