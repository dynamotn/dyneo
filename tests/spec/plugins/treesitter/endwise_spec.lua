local h = require('helpers')

describe('plugins.treesitter.endwise', function()
  before_each(function() h.globals() end)

  it('loads on the filetypes of the languages that close blocks', function()
    local spec = dofile(h.root .. '/lua/plugins/treesitter/endwise.lua')[1]
    local languages = require('config.languages')
    for name, language in pairs(languages) do
      for _, ft in ipairs(language.filetypes) do
        assert.equals(
          language.endwise == true,
          vim.list_contains(spec.ft, ft),
          name .. ' ' .. ft
        )
      end
    end
    assert.is_true(vim.list_contains(spec.ft, 'sh'))
  end)
end)
