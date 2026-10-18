local h = require('helpers')

describe('plugins.toolbox.picker', function()
  local restores, calls, snacks, lspconfig

  before_each(function()
    h.globals()
    calls = {}
    restores = {
      h.stub(_G, 'Snacks', {
        picker = setmetatable({}, {
          __index = function(_, name)
            return function(...) table.insert(calls, { name, ... }) end
          end,
        }),
        explorer = function(...) table.insert(calls, { 'explorer', ... }) end,
      }),
      h.stub(require('util.root'), 'get', function() return '/root/proj' end),
    }
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/picker.lua')) do
      if spec[1] == 'folke/snacks.nvim' then snacks = spec end
      if spec[1] == 'neovim/nvim-lspconfig' then lspconfig = spec end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  --- The Snacks calls pressing `lhs` of `keys` makes
  ---@param keys table[]
  ---@param lhs string
  ---@return table[]
  local function press(keys, lhs)
    for _, key in ipairs(keys) do
      if key[1] == lhs then
        calls = {}
        key[2]()
        return calls
      end
    end
    error('no key ' .. lhs)
  end

  it('opens every list through one Snacks picker', function()
    local functions = 0
    for _, key in ipairs(snacks.keys) do
      if type(key[2]) == 'function' then
        functions = functions + 1
        assert.are.equal(1, #press(snacks.keys, key[1]), key[1])
      else
        -- `<leader>e` and `<leader>E` are the explorer keys again
        assert.is_true(key.remap, key[1])
      end
    end
    assert.is_true(functions > 50)
  end)

  it('finds files from the root of the buffer unless told the cwd', function()
    assert.same(
      { { 'pick', 'files', { cwd = '/root/proj' } } },
      press(snacks.keys, '<leader>ff')
    )
    assert.same(
      { { 'pick', 'files', { root = false } } },
      press(snacks.keys, '<leader>fF')
    )
    assert.same(
      { { 'pick', 'grep', { cwd = '/root/proj' } } },
      press(snacks.keys, '<leader>sg')
    )
    assert.same(
      { { 'pick', 'files', { cwd = vim.fn.stdpath('config') } } },
      press(snacks.keys, '<leader>fc')
    )
    assert.same(
      { { 'buffers', { hidden = true, nofile = true } } },
      press(snacks.keys, '<leader>fB')
    )
    assert.same(
      { { 'explorer', { cwd = '/root/proj' } } },
      press(snacks.keys, '<leader>fe')
    )
    assert.same({ { 'explorer' } }, press(snacks.keys, '<leader>fE'))
  end)

  it('lists the LSP answers of every server through the picker', function()
    local keys = lspconfig.opts.servers['*'].keys
    assert.same({ { 'lsp_definitions' } }, press(keys, 'gd'))
    assert.same({ { 'lsp_references' } }, press(keys, 'gr'))
    assert.same({ { 'lsp_implementations' } }, press(keys, 'gI'))
    assert.same({ { 'lsp_type_definitions' } }, press(keys, 'gy'))
    assert.same({ { 'lsp_incoming_calls' } }, press(keys, '<leader>cki'))
    assert.same({ { 'lsp_outgoing_calls' } }, press(keys, '<leader>cko'))
    local filter = require('config.defaults').kind_filter
    assert.same(
      { { 'lsp_symbols', { filter = filter } } },
      press(keys, '<leader>ss')
    )
    assert.same(
      { { 'lsp_workspace_symbols', { filter = filter } } },
      press(keys, '<leader>sS')
    )
  end)

  describe('actions', function()
    local actions

    before_each(function() actions = snacks.opts.picker.actions end)

    it('switches the picker between the root and the cwd', function()
      local current, set, found
      local picker = {
        input = { filter = { current_buf = 0 } },
        cwd = function() return current end,
        set_cwd = function(_, cwd) set = cwd end,
        find = function() found = true end,
      }
      local cwd = vim.fs.normalize(vim.uv.cwd() or '.')
      current = '/root/proj'
      actions.toggle_cwd(picker)
      assert.are.equal(cwd, set)
      assert.is_true(found)
      current = cwd
      actions.toggle_cwd(picker)
      assert.are.equal('/root/proj', set)
    end)

    it('hands the results to trouble', function()
      table.insert(
        restores,
        h.stub(package.loaded, 'trouble.sources.snacks', {
          actions = {
            trouble_open = { action = function(...) return { ... } end },
          },
        })
      )
      assert.same({ 'picker', 'item' }, actions.trouble_open('picker', 'item'))
    end)

    it('jumps to a result by its flash label', function()
      local jumped, moved
      table.insert(
        restores,
        h.stub(package.loaded, 'flash', {
          jump = function(opts) jumped = opts end,
        })
      )
      local picker = {
        list = {
          row2idx = function(_, row) return row * 10 end,
          _move = function(_, idx, a, b) moved = { idx, a, b } end,
        },
      }
      actions.flash(picker)
      assert.are.equal('^', jumped.pattern)

      local exclude = jumped.search.exclude[1]
      local list = h.buffer({ filetype = 'snacks_picker_list' })
      vim.api.nvim_set_current_buf(list)
      assert.is_false(exclude(vim.api.nvim_get_current_win()))
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'lua' }))
      assert.is_true(exclude(vim.api.nvim_get_current_win()))

      jumped.action({ pos = { 3, 0 } })
      assert.same({ 30, true, true }, moved)
    end)
  end)
end)
