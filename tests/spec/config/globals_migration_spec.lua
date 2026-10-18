local h = require('helpers')

-- The settings moved from names of their own in `_G` to fields of `DyNeo`.
-- An assignment to a field `config.globals` never declares, or to the old
-- global, is silently ignored, so both are caught here.
describe('DyNeo settings', function()
  local declared
  before_each(function()
    h.globals()
    declared = vim.tbl_keys(DyNeo)
  end)

  it('are all declared that the per-machine template sets', function()
    local template =
      vim.fn.readfile(h.root .. '/lua/per_machine/config.lua.tmpl')
    for _, line in ipairs(template) do
      local field = line:match('^DyNeo%.([%w_]+)')
      if field then
        assert.is_true(vim.list_contains(declared, field), field)
      end
    end
  end)

  it('are no longer read or written as globals of their own', function()
    local files = { h.root .. '/init.lua' }
    for _, glob in ipairs({
      'lua/**/*.lua',
      'lua/**/*.tmpl',
      'plugin/**/*.lua',
      'ftplugin/**/*.lua',
      'after/**/*.lua',
      'lsp/**/*.lua',
      'scripts/**/*.lua',
      '.github/**/*.yml',
    }) do
      vim.list_extend(files, vim.fn.globpath(h.root, glob, false, true))
    end
    -- Enough to know the globs reached the tree
    assert.is_true(#files > 100, tostring(#files))
    for _, file in ipairs(files) do
      for number, line in ipairs(vim.fn.readfile(file)) do
        -- One check for the few lines that mention `_G` at all, before the
        -- one per setting: under luacov every line costs
        if line:find('_G.', 1, true) then
          for _, name in ipairs(declared) do
            assert.is_nil(
              line:find('_G.' .. name .. '%f[^%w_]'),
              ('%s:%d still uses _G.%s'):format(file, number, name)
            )
          end
        end
      end
    end
  end)
end)
