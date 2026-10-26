local h = require('helpers')

describe('plugins.toolbox.navigation', function()
  local restores

  --- The specs the file returns, keyed by plugin name
  ---@return table<string, table>
  local function load()
    local found = {}
    for _, spec in
      ipairs(dofile(h.root .. '/lua/plugins/toolbox/navigation.lua'))
    do
      found[spec[1]] = spec
    end
    return found
  end

  --- A module whose every function records its name and arguments
  ---@param calls table[]
  ---@return table
  local function recorder(calls)
    return setmetatable({}, {
      __index = function(_, name)
        return function(...) table.insert(calls, { name, ... }) end
      end,
    })
  end

  before_each(function()
    h.globals()
    restores = {}
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('resizes into zellij or tmux through their backend plugins', function()
    local splits = load()['mrjones2014/smart-splits.nvim']
    local mains = {}
    for _, dep in ipairs(splits.dependencies) do
      mains[dep.main] = dep
    end
    for _, backend in ipairs(splits.opts.mux.backend) do
      assert.is_truthy(mains[backend], backend .. ' is not installed')
    end
    assert.same(
      { 'smart-splits-backend-zellij-lua', 'smart-splits-backend-tmux' },
      splits.opts.mux.backend
    )
    assert.is_false(splits.opts.mux.warn_if_unusable)
    assert.is_true(
      mains['smart-splits-backend-zellij-lua'].opts.move_cursor.pane_or_tab
    )
  end)

  it('jumps, selects and searches through flash', function()
    local calls = {}
    table.insert(restores, h.stub(package.loaded, 'flash', recorder(calls)))
    local flash = load()['folke/flash.nvim']
    for _, key in ipairs(flash.keys) do
      key[2]()
    end
    assert.are.equal(#flash.keys, #calls)
    assert.same({ 'jump' }, calls[1])
    assert.same({ 'treesitter' }, calls[2])
    assert.same({ 'remote' }, calls[3])
    assert.same({ 'treesitter_search' }, calls[4])
    assert.same({ 'toggle' }, calls[5])
    assert.same({
      'treesitter',
      { actions = { ['<c-space>'] = 'next', ['<BS>'] = 'prev' } },
    }, calls[6])
  end)

  it('moves, resizes and swaps windows through smart-splits', function()
    local calls = {}
    table.insert(
      restores,
      h.stub(package.loaded, 'smart-splits', recorder(calls))
    )
    local splits = load()['mrjones2014/smart-splits.nvim']
    local called = {}
    for _, key in ipairs(splits.keys) do
      key[2]()
      called[key[1]] = calls[#calls][1]
    end
    assert.are.equal(#splits.keys, #calls)
    assert.are.equal('move_cursor_left', called['<S-Left>'])
    assert.are.equal('move_cursor_previous', called['<C-\\>'])
    assert.are.equal('resize_up', called['<C-Up>'])
    assert.are.equal('swap_buf_right', called['<leader>w<Right>'])
    assert.are.equal('stop', splits.opts.move.at_edge)
    assert.is_true(splits.opts.swap.move_cursor)
  end)

  it('toggles and expands the lists through quicker', function()
    local calls = {}
    table.insert(restores, h.stub(package.loaded, 'quicker', recorder(calls)))
    local quicker = load()['stevearc/quicker.nvim']
    for _, key in ipairs(quicker.keys) do
      key[2]()
    end
    for _, key in ipairs(quicker.opts.keys) do
      key[2]()
    end
    assert.same({
      { 'toggle', { focus = true } },
      { 'toggle', { focus = true, loclist = true } },
      { 'expand', { before = 2, after = 2, add_to_existing = true } },
      { 'collapse' },
    }, calls)
  end)
end)
