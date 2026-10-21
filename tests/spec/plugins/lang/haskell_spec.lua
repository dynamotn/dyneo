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

  it('holds hls off a held buffer until released', function()
    local started, executables = {}, { 'haskell-language-server' }
    table.insert(
      restores,
      h.stub(
        vim.fn,
        'executable',
        function(name) return vim.list_contains(executables, name) and 1 or 0 end
      )
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'haskell-tools', {
        lsp = { start = function(bufnr) table.insert(started, bufnr) end },
      })
    )
    table.insert(restores, function() vim.g.haskell_tools = nil end)
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    table.insert(restores, function() untrusted.forget('/work/held') end)
    vim.g.haskell_tools = { tools = { x = 1 } }
    local tools = spec('mrcjkb/haskell-tools.nvim')
    tools.init()
    tools.config()
    assert.are.equal(1, vim.g.haskell_tools.tools.x)
    local auto_attach = vim.g.haskell_tools.hls.auto_attach
    local held = h.buffer({ name = '/work/held/Main.hs', filetype = 'haskell' })
    local free = h.buffer({ name = '/work/free/Main.hs', filetype = 'haskell' })
    untrusted.hold('/work/held')
    vim.api.nvim_set_current_buf(held)
    assert.is_false(auto_attach())
    vim.api.nvim_set_current_buf(free)
    assert.is_true(auto_attach())
    executables = {}
    assert.is_false(auto_attach())
    -- Released on a machine without hls, nothing is started either
    untrusted.release('/work/held')
    assert.same({}, started)
    untrusted.hold('/work/held')
    executables = { 'haskell-language-server-wrapper' }
    untrusted.release('/work/held')
    assert.same({ held }, started)
  end)

  it('starts hls for a released cabal file only when hls reads it', function()
    local started, supported = {}, false
    table.insert(
      restores,
      h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'haskell-language-server' and 1 or 0 end
      )
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'haskell-tools', {
        lsp = { start = function(bufnr) table.insert(started, bufnr) end },
      })
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'haskell-tools.lsp.helpers', {
        is_hls_version_with_cabal_support = function() return supported end,
      })
    )
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    table.insert(restores, function() untrusted.forget('/work/held') end)
    spec('mrcjkb/haskell-tools.nvim').config()
    local cabal = h.buffer({ name = '/work/held/a.cabal', filetype = 'cabal' })
    local project =
      h.buffer({ name = '/work/held/cabal.project', filetype = 'cabalproject' })
    untrusted.hold('/work/held')
    untrusted.release('/work/held')
    assert.same({}, started)
    untrusted.hold('/work/held')
    supported = true
    untrusted.release('/work/held')
    assert.same({ cabal, project }, started)
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
