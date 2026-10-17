local h = require('helpers')

--- The spec of `name` in the plugin file at `path`
---@param path string
---@param name string
---@return table
local function spec_of(path, name)
  for _, spec in ipairs(dofile(h.root .. '/' .. path)) do
    if spec[1] == name then return spec end
    for _, inner in ipairs(spec) do
      if type(inner) == 'table' and inner[1] == name then return inner end
    end
  end
  error(name .. ' not found in ' .. path)
end

describe('plugin autocmds set up twice', function()
  before_each(function() h.globals() end)

  it('keep one bufferline redraw', function()
    local restore =
      h.stub(package.loaded, 'bufferline', { setup = function() end })
    local spec = spec_of('lua/plugins/ui/status.lua', 'akinsho/bufferline.nvim')
    spec.config(nil, {})
    spec.config(nil, {})
    restore()
    local hooks = vim.api.nvim_get_autocmds({
      group = 'dyneo_bufferline',
      event = 'BufAdd',
    })
    assert.equals(1, #hooks)
  end)

  it('keep one parser override per `:TSUpdate`', function()
    local restores = {
      h.stub(package.loaded, 'nvim-treesitter', {
        get_installed = function() return {} end,
        setup = function() end,
        install = function()
          return { await = function() end }
        end,
      }),
      h.stub(package.loaded, 'nvim-treesitter.parsers', {}),
      h.stub(package.loaded, 'util.treesitter', {
        get_installed = function() return {} end,
        have = function() return true end,
        build = function() end,
      }),
      h.stub(package.loaded, 'util.lazy_install', {
        on_filetype = function() end,
      }),
    }
    local spec = spec_of(
      'lua/plugins/treesitter/parser.lua',
      'nvim-treesitter/nvim-treesitter'
    )
    local function count()
      return #vim.api.nvim_get_autocmds({
        group = 'dyneo_treesitter_parsers',
        event = 'User',
      })
    end
    spec.config(nil, vim.deepcopy(spec.opts))
    local once = count()
    spec.config(nil, vim.deepcopy(spec.opts))
    for i = #restores, 1, -1 do
      restores[i]()
    end
    local twice = count()
    -- The stubs live on in these handlers
    vim.api.nvim_del_augroup_by_name('dyneo_treesitter')
    vim.api.nvim_del_augroup_by_name('dyneo_treesitter_parsers')
    assert.is_true(once > 0)
    assert.equals(once, twice)
  end)

  it('keep one CMake project check', function()
    local spec =
      spec_of('lua/plugins/lang/cmake.lua', 'Civitasv/cmake-tools.nvim')
    -- One hook per filetype it watches
    local function hooks()
      return #vim.api.nvim_get_autocmds({
        group = 'dyneo_cmake',
        event = 'FileType',
      })
    end
    spec.init()
    local once = hooks()
    spec.init()
    assert.equals(once, hooks())
  end)
end)
