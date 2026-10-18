local h = require('helpers')

local file = h.root .. '/lua/plugins/treesitter/textobjects.lua'

---@return table
local function spec()
  for _, plugin in ipairs(dofile(file)) do
    if plugin[1] == 'nvim-treesitter/nvim-treesitter-textobjects' then
      return plugin
    end
  end
  error('no textobjects spec')
end

describe('plugins.treesitter.textobjects', function()
  local restores, textobjects, moves, swaps, have

  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    h.globals()
    restores = {}
    moves, swaps = {}, {}
    have = {}
    textobjects = { setup = function(opts) textobjects.setup_opts = opts end }
    stub(package.loaded, 'nvim-treesitter-textobjects', textobjects)
    stub(
      package.loaded,
      'nvim-treesitter-textobjects.move',
      setmetatable({}, {
        __index = function(_, method)
          return function(query, group)
            table.insert(moves, { method, query, group })
          end
        end,
      })
    )
    stub(package.loaded, 'nvim-treesitter-textobjects.swap', {
      swap_next = function(q) table.insert(swaps, 'next:' .. q) end,
      swap_previous = function(q) table.insert(swaps, 'prev:' .. q) end,
    })
    stub(
      require('util.treesitter'),
      'have',
      function(ft, query) return have[ft .. ':' .. query] == true end
    )
  end)
  after_each(function()
    pcall(vim.api.nvim_del_augroup_by_name, 'dyneo_treesitter_textobjects')
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('swaps parameters from its keys', function()
    for _, key in ipairs(spec().keys) do
      key[2]()
    end
    assert.same({ 'next:@parameter.inner', 'prev:@parameter.inner' }, swaps)
  end)

  it('asks for an update when the plugin is too old', function()
    textobjects.setup = nil
    local errors = {}
    stub(
      require('util.plugin'),
      'error',
      function(msg) table.insert(errors, msg) end
    )
    local plugin = spec()
    plugin.config(nil, plugin.opts)
    assert.equals(1, #errors)
    assert.is_truthy(errors[1]:find('update', 1, true))
    assert.is_nil(textobjects.setup_opts)
  end)

  --- The buffer-local mappings of `bufnr`, by lhs
  ---@param bufnr integer
  ---@param mode string
  ---@return table<string, table>
  local function maps(bufnr, mode)
    local found = {}
    for _, map in ipairs(vim.api.nvim_buf_get_keymap(bufnr, mode)) do
      found[map.lhs] = map
    end
    return found
  end

  it('maps the moves in a buffer whose language has the query', function()
    have['lua:textobjects'] = true
    local lua = h.buffer({ filetype = 'lua' })
    local text = h.buffer({ filetype = 'text' })
    local plugin = spec()
    plugin.config(nil, plugin.opts)
    assert.equals(plugin.opts, textobjects.setup_opts)

    -- Buffers already open are set up
    local lua_maps = maps(lua, 'n')
    assert.equals('Next Function Start', lua_maps[']f'].desc)
    assert.equals('Prev Class End', lua_maps['[C'].desc)
    assert.equals('Next Parameter End', lua_maps[']A'].desc)
    assert.is_not_nil(maps(lua, 'x')[']f'])
    assert.is_not_nil(maps(lua, 'o')[']f'])
    assert.is_nil(maps(text, 'n')[']f'])

    -- And a buffer opened later
    local later = h.buffer({ filetype = 'lua' })
    assert.equals('Prev Parameter Start', maps(later, 'n')['[a'].desc)

    vim.api.nvim_set_current_buf(lua)
    lua_maps[']f'].callback()
    lua_maps['[C'].callback()
    assert.same({
      { 'goto_next_start', '@function.outer', 'textobjects' },
      { 'goto_previous_end', '@class.outer', 'textobjects' },
    }, moves)
  end)

  it('names a move over several queries', function()
    have['lua:textobjects'] = true
    local lua = h.buffer({ filetype = 'lua' })
    local plugin = spec()
    local opts = vim.deepcopy(plugin.opts)
    opts.move.keys = {
      goto_next_start = { [']o'] = { '@loop.inner', '@conditional.outer' } },
    }
    plugin.config(nil, opts)
    assert.equals('Next Loop or Conditional Start', maps(lua, 'n')[']o'].desc)
  end)

  it('keeps ]c and [c moving between changes in a diff', function()
    have['lua:textobjects'] = true
    local lua = h.buffer({ filetype = 'lua' })
    local plugin = spec()
    plugin.config(nil, plugin.opts)
    vim.api.nvim_set_current_buf(lua)
    local normal = {}
    stub(vim, 'cmd', function(cmd) table.insert(normal, cmd) end)
    vim.wo.diff = true
    maps(lua, 'n')[']c'].callback()
    maps(lua, 'n')['[C'].callback()
    maps(lua, 'n')[']f'].callback()
    vim.wo.diff = false
    assert.same({ 'normal! ]c', 'normal! [C' }, normal)
    assert.same(
      { { 'goto_next_start', '@function.outer', 'textobjects' } },
      moves
    )
  end)

  it('maps nothing while moves are off', function()
    have['lua:textobjects'] = true
    local lua = h.buffer({ filetype = 'lua' })
    local plugin = spec()
    plugin.config(nil, { move = { enable = false } })
    assert.is_nil(maps(lua, 'n')[']f'])
  end)
end)
