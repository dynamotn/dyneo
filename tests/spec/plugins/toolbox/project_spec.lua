local h = require('helpers')

describe('plugins.toolbox.project', function()
  local restores, specs

  --- The spec of `name` among those the file returns
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
    specs = dofile(h.root .. '/lua/plugins/toolbox/project.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('opens the alternative file beside the buffer', function()
    local opened = false
    table.insert(
      restores,
      h.stub(package.loaded, 'other-nvim', {
        openVSplit = function() opened = true end,
      })
    )
    local other = spec('rgroli/other.nvim')
    assert.are.equal('other-nvim', other.main)
    assert.are.equal('<leader>pa', other.keys[1][1])
    other.keys[1][2]()
    assert.is_true(opened)
    -- A bats test sits next to the script it covers
    local bats = other.opts.mappings[#other.opts.mappings]
    assert.are.equal('/test/%1.bats', bats.target)
  end)

  it('reads devcontainer.json with the JSON parser', function()
    local devcontainer = spec('esensar/nvim-dev-container')
    local opts = { ensure_installed = { 'lua' } }
    devcontainer.dependencies.opts(nil, opts)
    assert.same({ 'lua', 'json' }, opts.ensure_installed)
    assert.is_true(vim.list_contains(devcontainer.cmd, 'DevcontainerStart'))
    assert.are.equal('<leader>pd', devcontainer.keys[1][1])
  end)

  it('groups the project keys for which-key', function()
    local groups = {}
    for _, entry in ipairs(spec('folke/which-key.nvim').opts.spec) do
      groups[entry[1]] = entry.group
    end
    assert.are.equal('project', groups['<leader>p'])
    assert.is_not_nil(groups['<leader>ps'])
    assert.are.equal('Codesettings', spec('mrjones2014/codesettings.nvim').cmd)
  end)
end)
