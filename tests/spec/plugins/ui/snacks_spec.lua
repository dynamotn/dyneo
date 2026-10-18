local h = require('helpers')

local file = h.root .. '/lua/plugins/ui/snacks.lua'

---@return table
local function spec() return dofile(file)[1] end

---@param lhs string
---@return table
local function key_of(lhs)
  for _, key in ipairs(spec().keys) do
    if key[1] == lhs then return key end
  end
  error('no key ' .. lhs)
end

describe('plugins.ui.snacks', function()
  local restores, snacks, calls

  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    h.globals()
    restores = {}
    calls = {}
    local function record(name)
      return function() table.insert(calls, name) end
    end
    snacks = {
      config = {},
      picker = { notifications = record('picker') },
      notifier = { show_history = record('history'), hide = record('hide') },
      scratch = setmetatable(
        { select = record('select') },
        { __call = record('scratch') }
      ),
      profiler = { scratch = record('profiler') },
    }
    stub(_G, 'Snacks', snacks)
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it(
    'maps the toggles through the safe keymap',
    function()
      assert.equals(
        require('util.plugin').safe_keymap_set,
        spec().opts.toggle.map
      )
    end
  )

  it('leaves <C-hjkl> to the program in a floating terminal', function()
    local keys = spec().opts.terminal.win.keys
    local floating = { is_floating = function() return true end }
    assert.equals('<c-h>', keys.nav_h[2](floating))
    assert.equals('<c-j>', keys.nav_j[2](floating))
    assert.equals('<c-k>', keys.nav_k[2](floating))
    assert.equals('<c-l>', keys.nav_l[2](floating))
  end)

  it('leaves a split terminal for the next window', function()
    local moved = {}
    stub(vim.cmd, 'wincmd', function(dir) table.insert(moved, dir) end)
    local keys = spec().opts.terminal.win.keys
    local split = { is_floating = function() return false end }
    assert.is_nil(keys.nav_h[2](split))
    assert.is_nil(keys.nav_l[2](split))
    vim.wait(100, function() return #moved == 2 end)
    assert.same({ 'h', 'l' }, moved)
  end)

  it('picks from the dashboard with the configured picker', function()
    local picked
    stub(package.loaded, 'util.pick', function(cmd, opts)
      return function()
        picked = { cmd, opts }
        return 'picked'
      end
    end)
    assert.equals(
      'picked',
      spec().opts.dashboard.preset.pick('files', { cwd = '/x' })
    )
    assert.same({ 'files', { cwd = '/x' } }, picked)
  end)

  it('shows the notification history in the picker when it is on', function()
    key_of('<leader>n')[2]()
    snacks.config.picker = { enabled = true }
    key_of('<leader>n')[2]()
    assert.same({ 'history', 'picker' }, calls)
  end)

  it('runs the other snacks from their keys', function()
    key_of('<leader>un')[2]()
    key_of('<leader>.')[2]()
    key_of('<leader>S')[2]()
    key_of('<leader>dps')[2]()
    assert.same({ 'hide', 'scratch', 'select', 'profiler' }, calls)
  end)

  it('hands vim.notify back for noice to take over', function()
    local original = vim.notify
    local replaced = function() end
    local setup_opts
    stub(package.loaded, 'snacks', {
      setup = function(opts)
        setup_opts = opts
        vim.notify = replaced
      end,
    })
    local has = false
    stub(require('util.plugin'), 'has', function() return has end)

    local plugin = spec()
    plugin.config(nil, plugin.opts)
    assert.equals(plugin.opts, setup_opts)
    assert.equals(replaced, vim.notify)

    has = true
    vim.notify = original
    plugin.config(nil, plugin.opts)
    assert.equals(original, vim.notify)
  end)
end)
