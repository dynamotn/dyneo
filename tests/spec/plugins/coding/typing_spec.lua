local h = require('helpers')

--- The spec of `name` in `plugins/coding/typing.lua`
---@param name string
---@return table
local function spec_of(name)
  for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/coding/typing.lua')) do
    if plugin[1] == name then return plugin end
  end
  error('no spec for ' .. name)
end

describe('plugins.coding.typing: nvim-autopairs', function()
  local restores, added, set_up

  before_each(function()
    h.globals()
    added = {}
    restores = {
      h.stub(package.loaded, 'nvim-autopairs', {
        setup = function(opts) set_up = opts end,
        add_rules = function(rules) vim.list_extend(added, rules) end,
      }),
      h.stub(package.loaded, 'nvim-autopairs.rule', 'rule'),
      h.stub(package.loaded, 'nvim-autopairs.conds', 'cond'),
      h.stub(package.loaded, 'nvim-autopairs.ts-conds', 'ts_cond'),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('adds the rules of every language that has some', function()
    local given
    table.insert(
      restores,
      h.stub(package.loaded, 'config.languages', {
        ruby = {
          filetypes = { 'ruby' },
          autopairs = function(filetypes, rule, cond, ts_cond)
            given = { filetypes, rule, cond, ts_cond }
            return { 'ruby-rule' }
          end,
        },
        c = { filetypes = { 'c' } },
      })
    )
    table.insert(
      restores,
      h.stub(
        require('util.languages'),
        'names',
        function() return { 'c', 'ruby' } end
      )
    )
    local autopairs = spec_of('windwp/nvim-autopairs')
    autopairs.config(nil, autopairs.opts)
    assert.equals(autopairs.opts, set_up)
    assert.same({ 'ruby-rule' }, added)
    assert.same({ { 'ruby' }, 'rule', 'cond', 'ts_cond' }, given)
  end)
end)

describe('plugins.coding.typing: text-case', function()
  it('puts its mappings under `ga`', function()
    local set_up
    local restore = h.stub(package.loaded, 'textcase', {
      setup = function(opts) set_up = opts end,
    })
    spec_of('johmsalas/text-case.nvim').config()
    restore()
    assert.same({ prefix = 'ga' }, set_up)
  end)
end)

describe('plugins.coding.typing: multicursor', function()
  local calls, mc, restore

  before_each(function()
    calls = {}
    mc = setmetatable({}, {
      __index = function(self, name)
        local fn = function(...) table.insert(calls, { name, ... }) end
        rawset(self, name, fn)
        return fn
      end,
    })
    restore = h.stub(package.loaded, 'multicursor-nvim', mc)
  end)
  after_each(function() restore() end)

  it('hands each key to the function it names, with its arguments', function()
    local keys = spec_of('jake-stewart/multicursor.nvim').keys()
    local by_lhs = {}
    for _, key in ipairs(keys) do
      by_lhs[key[1] .. (type(key.mode) == 'string' and key.mode or '')] = key
    end
    by_lhs['<C-n>'][2]()
    by_lhs['<leader>vN'][2]()
    by_lhs['<leader>vd'][2]()
    by_lhs['<leader>v[x'][2]()
    by_lhs['Ix'][2]()
    assert.same({
      { 'matchAddCursor', 1 },
      { 'matchAddCursor', -1 },
      {
        'diagnosticMatchCursors',
        { severity = vim.diagnostic.severity.ERROR },
      },
      { 'transposeCursors', -1 },
      { 'insertVisual' },
    }, calls)
    -- Every key has a callback and a description
    for _, key in ipairs(keys) do
      assert.is_function(key[2], key[1])
      assert.is_string(key.desc, key[1])
    end
  end)

  it('maps the cursor keys only while there are cursors', function()
    local set = {}
    local enabled = true
    rawset(mc, 'setup', function() table.insert(calls, { 'setup' }) end)
    rawset(mc, 'addKeymapLayer', function(fn)
      fn(
        function(mode, lhs, rhs, opts)
          set[lhs] = { mode = mode, rhs = rhs, desc = opts.desc }
        end
      )
    end)
    rawset(mc, 'cursorsEnabled', function() return enabled end)
    spec_of('jake-stewart/multicursor.nvim').config()
    assert.same({ { 'setup' } }, calls)
    assert.equals(mc.prevCursor, set['<Left>'].rhs)
    assert.equals(mc.nextCursor, set['<Right>'].rhs)
    assert.equals('Delete main cursor', set['<leader>vq'].desc)
    assert.equals(mc.sequenceIncrement, set['g<C-a>'].rhs)
    assert.equals(mc.sequenceDecrement, set['g<C-x>'].rhs)
    -- Escape clears enabled cursors, and enables disabled ones
    set['<Esc>'].rhs()
    enabled = false
    set['<Esc>'].rhs()
    assert.same({ { 'setup' }, { 'clearCursors' }, { 'enableCursors' } }, calls)
  end)
end)
