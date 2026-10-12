local h = require('helpers')

describe('plugins.coding.syntax', function()
  ---@param gentoo boolean Whether `/etc/gentoo-release` exists
  ---@return table spec The gentoo-syntax spec
  local function gentoo_on(gentoo)
    local fs_stat = vim.uv.fs_stat
    local restore = h.stub(vim.uv, 'fs_stat', function(path, ...)
      if path == '/etc/gentoo-release' then
        return gentoo and { type = 'file' } or nil
      end
      return fs_stat(path, ...)
    end)
    local specs = dofile(h.root .. '/lua/plugins/coding/syntax.lua')
    restore()
    for _, spec in ipairs(specs) do
      if spec[1] == 'gentoo/gentoo-syntax' then return spec end
    end
    error('no gentoo-syntax spec')
  end

  it('loads gentoo-syntax only on Gentoo', function()
    assert.is_true(gentoo_on(true).cond)
    assert.is_false(gentoo_on(false).cond)
  end)
end)
