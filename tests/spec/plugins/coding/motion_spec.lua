local h = require('helpers')

--- The spec of `name` in `plugins/coding/motion.lua`
---@param name string
---@return table
local function spec_of(name)
  for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/coding/motion.lua')) do
    if plugin[1] == name then return plugin end
  end
  error('no spec for ' .. name)
end

describe('plugins.coding.motion: harpoon', function()
  local calls, restore

  before_each(function()
    calls = {}
    local list = {
      add = function() table.insert(calls, 'add') end,
      select = function(_, i) table.insert(calls, 'select ' .. i) end,
    }
    restore = h.stub(package.loaded, 'harpoon', {
      list = function() return list end,
      ui = {
        toggle_quick_menu = function(_, l)
          table.insert(calls, l == list and 'menu' or 'menu of ?')
        end,
      },
    })
  end)
  after_each(function() restore() end)

  it('pins, lists and jumps to the nine first files', function()
    local keys = spec_of('ThePrimeagen/harpoon').keys()
    assert.equals(11, #keys)
    for _, key in ipairs(keys) do
      key[2]()
    end
    assert.same({
      'add',
      'menu',
      'select 1',
      'select 2',
      'select 3',
      'select 4',
      'select 5',
      'select 6',
      'select 7',
      'select 8',
      'select 9',
    }, calls)
    assert.equals('<leader>9', keys[11][1])
  end)
end)

describe('plugins.coding.motion: mini.surround', function()
  local restore, opts

  before_each(function()
    restore = h.stub(require('util.plugin'), 'opts', function(name)
      assert.equals('mini.surround', name)
      return opts
    end)
  end)
  after_each(function() restore() end)

  it('loads on the keys the options map, after the given ones', function()
    opts = spec_of('nvim-mini/mini.surround').opts
    local keys = spec_of('nvim-mini/mini.surround').keys(nil, { { 'gsx' } })
    assert.equals(8, #keys)
    assert.equals('gsa', keys[1][1])
    assert.same({ 'n', 'x' }, keys[1].mode)
    assert.equals('gsx', keys[8][1])
  end)

  it('leaves out a mapping turned off', function()
    opts = { mappings = { add = 'gsa', delete = '', find = 'gsf' } }
    local keys = spec_of('nvim-mini/mini.surround').keys(nil, {})
    assert.same({ 'gsa', 'gsf' }, { keys[1][1], keys[2][1] })
    assert.equals(2, #keys)
  end)
end)

describe('plugins.coding.motion: mini.ai', function()
  local restores, specs

  before_each(function()
    specs = {}
    restores = {
      h.stub(package.loaded, 'mini.ai', {
        gen_spec = {
          treesitter = function(spec)
            table.insert(specs, spec)
            return { treesitter = spec }
          end,
          function_call = function(opts)
            table.insert(specs, opts or 'call')
            return { call = opts }
          end,
        },
        setup = function(opts) specs.set_up = opts end,
      }),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('builds its text objects from Treesitter and the buffer', function()
    local opts = spec_of('nvim-mini/mini.ai').opts()
    assert.equals(500, opts.n_lines)
    assert.same(
      { a = '@function.outer', i = '@function.inner' },
      opts.custom_textobjects.f.treesitter
    )
    assert.equals(require('util.mini').ai_buffer, opts.custom_textobjects.g)
    assert.same({ name_pattern = '[%w_]' }, opts.custom_textobjects.U.call)
    assert.is_nil(opts.custom_textobjects.u.call)
  end)

  it('names the text objects in which-key once it has loaded', function()
    local added
    table.insert(
      restores,
      h.stub(package.loaded, 'which-key', {
        add = function(spec) added = spec end,
      })
    )
    local opts = { mappings = { around = 'a', inside = 'i' } }
    spec_of('nvim-mini/mini.ai').config(nil, opts)
    assert.equals(opts, specs.set_up)
    assert.is_nil(added)
    vim.api.nvim_exec_autocmds(
      'User',
      { pattern = 'LazyLoad', data = 'which-key.nvim' }
    )
    vim.wait(200, function() return added ~= nil end, 5)
    assert.same({ 'o', 'x' }, added.mode)
    assert.is_true(#added > 2)
  end)
end)

describe('plugins.coding.motion: vim-matchup', function()
  it('defers the highlight and keeps the status line clear', function()
    local before = {
      vim.g.matchup_matchparen_offscreen,
      vim.g.matchup_matchparen_deferred,
      vim.g.matchup_transmute_enabled,
    }
    spec_of('andymass/vim-matchup').init()
    assert.same({ method = 'popup' }, vim.g.matchup_matchparen_offscreen)
    assert.equals(1, vim.g.matchup_matchparen_deferred)
    assert.equals(0, vim.g.matchup_transmute_enabled)
    vim.g.matchup_matchparen_offscreen = before[1]
    vim.g.matchup_matchparen_deferred = before[2]
    vim.g.matchup_transmute_enabled = before[3]
  end)
end)
