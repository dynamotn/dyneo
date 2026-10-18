local h = require('helpers')

describe('plugins.toolbox.misc', function()
  local specs

  --- The spec of `name` among those the file returns
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
    specs = dofile(h.root .. '/lua/plugins/toolbox/misc.lua')
  end)

  it('never loads kulala on the way out', function()
    local kulala = spec('mistweaverco/kulala.nvim')
    assert.same(
      { 'BufReadPre', 'BufNewFile' },
      kulala.event(nil, { 'VimLeavePre', 'BufReadPre', 'BufNewFile' })
    )
    assert.same({}, kulala.event(nil, nil))
    assert.are.equal('http', kulala.ft)
    for _, key in ipairs(kulala.keys) do
      assert.are.equal('string', type(key[2]), key[1])
    end
  end)

  it('averages the startup time over ten runs', function()
    local original = vim.g.startuptime_tries
    spec('dstein64/vim-startuptime').config()
    assert.are.equal(10, vim.g.startuptime_tries)
    vim.g.startuptime_tries = original
    assert.same(
      { 'http', 'graphql' },
      spec('nvim-treesitter/nvim-treesitter').opts.ensure_installed
    )
  end)
end)
