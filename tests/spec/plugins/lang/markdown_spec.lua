local h = require('helpers')

describe('plugins.lang.markdown', function()
  local dir, cleanup

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    DyNeo.enabled_plugins.obsidian = true
  end)
  after_each(function() cleanup() end)

  --- The obsidian.nvim spec, read with these vaults configured
  ---@param paths table<string, string>
  local function obsidian(paths)
    DyNeo.obsidian.paths = paths
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/markdown.lua')) do
      if spec[1] == 'obsidian-nvim/obsidian.nvim' then return spec end
    end
  end

  it('loads obsidian.nvim for the notes of a vault only', function()
    vim.fn.mkdir(dir .. '/notes', 'p')
    local spec = obsidian({ notes = dir .. '/notes', gone = dir .. '/gone' })
    assert.is_true(spec.enabled)
    assert.is_nil(spec.ft)
    assert.same(
      { { name = 'notes', path = dir .. '/notes' } },
      spec.opts.workspaces
    )
    assert.same({
      'BufReadPre ' .. dir .. '/notes/*.md',
      'BufNewFile ' .. dir .. '/notes/*.md',
    }, spec.event)
  end)

  it(
    'leaves obsidian.nvim out without a vault on this machine',
    function() assert.is_false(obsidian({ gone = dir .. '/gone' }).enabled) end
  )
end)
