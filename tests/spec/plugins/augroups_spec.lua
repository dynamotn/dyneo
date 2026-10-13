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

  it('keep one CMake project check', function()
    local spec =
      spec_of('lua/plugins/lang/cmake.lua', 'Civitasv/cmake-tools.nvim')
    spec.init()
    spec.init()
    local hooks = vim.api.nvim_get_autocmds({
      group = 'dyneo_cmake',
      event = 'DirChanged',
    })
    assert.equals(1, #hooks)
  end)
end)
