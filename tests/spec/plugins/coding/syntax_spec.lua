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

describe('plugins.coding.syntax: gentoo-syntax config', function()
  it('drops its ebuild detection, keeping the other patterns', function()
    local group =
      vim.api.nvim_create_augroup('filetypedetect', { clear = false })
    local before = #vim.api.nvim_get_autocmds({ group = 'filetypedetect' })
    vim.api.nvim_create_autocmd('BufRead', {
      group = group,
      pattern = '*.e{build,class}',
      command = 'setf ebuild',
    })
    vim.api.nvim_create_autocmd('BufRead', {
      group = group,
      pattern = '*.eclass2',
      command = 'setf other',
    })
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/coding/syntax.lua')) do
      if spec[1] == 'gentoo/gentoo-syntax' then spec.config() end
    end
    local left = vim.api.nvim_get_autocmds({ group = 'filetypedetect' })
    assert.equals(before + 1, #left)
    local patterns = vim.tbl_map(function(au) return au.pattern end, left)
    assert.is_true(vim.list_contains(patterns, '*.eclass2'))
    assert.is_false(vim.list_contains(patterns, '*.e{build,class}'))
    vim.api.nvim_clear_autocmds({ group = group, pattern = '*.eclass2' })
  end)
end)
