local h = require('helpers')

describe('plugins.lang.haskell', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.haskell` returns
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
    specs = dofile(h.root .. '/lua/plugins/lang/haskell.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('drives the project files too, and leaves hls to haskell-tools', function()
    local tools = spec('mrcjkb/haskell-tools.nvim')
    assert.same({ 'haskell', 'cabal', 'cabalproject' }, tools.ft)
    assert.is_false(tools.version)
    assert.is_true(spec('neovim/nvim-lspconfig').opts.setup.hls())
  end)

  it('opens the REPL of the package or of the buffer', function()
    local calls = {}
    table.insert(
      restores,
      h.stub(package.loaded, 'haskell-tools', {
        hoogle = {
          hoogle_signature = function() table.insert(calls, 'hoogle') end,
        },
        repl = {
          toggle = function(file) table.insert(calls, { 'repl', file }) end,
        },
      })
    )
    vim.api.nvim_set_current_buf(h.buffer({ name = '/tmp/dy/Main.hs' }))
    local keys = {}
    for _, key in ipairs(spec('mrcjkb/haskell-tools.nvim').keys) do
      keys[key[1]] = key
      assert.same({ 'haskell' }, key.ft)
    end
    assert.are.equal('<cmd>Haskell hls evalAll<cr>', keys['<localleader>e'][2])
    keys['<localleader>h'][2]()
    keys['<localleader>r'][2]()
    keys['<localleader>R'][2]()
    assert.same({ 'hoogle', { 'repl' }, { 'repl', '/tmp/dy/Main.hs' } }, calls)
  end)

  it('adds the Haskell snippets to LuaSnip', function()
    local added
    table.insert(
      restores,
      h.stub(package.loaded, 'luasnip', {
        add_snippets = function(ft, snippets, opts)
          added = { ft = ft, snippets = snippets, opts = opts }
        end,
      })
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'haskell-snippets', { all = { 'snippet' } })
    )
    spec('mrcjkb/haskell-snippets.nvim').config()
    assert.same(
      { ft = 'haskell', snippets = { 'snippet' }, opts = { key = 'haskell' } },
      added
    )
  end)
end)
