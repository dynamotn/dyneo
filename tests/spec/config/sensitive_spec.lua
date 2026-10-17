local config = require('config.sensitive')

describe('config.sensitive', function()
  it('lists valid Lua patterns', function()
    assert.is_true(#config.name_patterns > 0)
    for _, pattern in ipairs(config.name_patterns) do
      assert.are.equal('string', type(pattern))
      assert(pcall(string.match, 'x', pattern), 'bad pattern ' .. pattern)
    end
  end)

  it('writes name and path patterns in lower case', function()
    -- They are matched against the lower-cased path
    for _, list in ipairs({ config.name_patterns, config.path_patterns }) do
      for _, pattern in ipairs(list) do
        assert(pcall(string.match, 'x', pattern), 'bad pattern ' .. pattern)
        assert.are.equal(
          pattern:gsub('%%%a', ''):lower(),
          pattern:gsub('%%%a', '')
        )
      end
    end
  end)

  it('keys directory names to true', function()
    for name, flag in pairs(config.dirs) do
      assert.are.equal('string', type(name))
      assert.are.equal(name:lower(), name)
      assert.is_nil(name:find('/', 1, true))
      assert.is_true(flag)
    end
  end)

  it('lists absolute paths', function()
    for _, path in ipairs(config.paths) do
      assert.is_true(vim.startswith(path, '/'))
    end
  end)

  it(
    'treats commit messages as sensitive',
    function() assert.is_true(vim.list_contains(config.filetypes, 'gitcommit')) end
  )
end)
