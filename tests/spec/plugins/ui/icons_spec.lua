local h = require('helpers')

describe('plugins.ui.icons', function()
  local restores

  before_each(function()
    h.globals()
    restores = {
      h.stub(package.preload, 'nvim-web-devicons', nil),
      h.stub(package.loaded, 'nvim-web-devicons', nil),
      h.stub(package.loaded, 'mini.icons', nil),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('stands in for nvim-web-devicons', function()
    local mocked = 0
    package.loaded['mini.icons'] = {
      mock_nvim_web_devicons = function()
        mocked = mocked + 1
        package.loaded['nvim-web-devicons'] = { mocked = true }
      end,
    }
    dofile(h.root .. '/lua/plugins/ui/icons.lua')[1].init()
    assert.equals('function', type(package.preload['nvim-web-devicons']))
    assert.is_nil(package.loaded['nvim-web-devicons'])

    local devicons = require('nvim-web-devicons')
    assert.same({ mocked = true }, devicons)
    assert.equals(1, mocked)
    -- Cached from then on
    assert.equals(devicons, require('nvim-web-devicons'))
    assert.equals(1, mocked)
  end)
end)
