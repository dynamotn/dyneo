local h = require('helpers')

describe('plugins.lang.swift', function()
  local mac, restore

  before_each(function()
    h.globals()
    restore = h.stub(
      vim.fn,
      'has',
      function(feature) return (feature == 'mac' and mac) and 1 or 0 end
    )
  end)
  after_each(function() restore() end)

  --- The xcodebuild.nvim spec
  local function xcodebuild()
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/swift.lua')) do
      if spec[1] == 'wojciech-kulik/xcodebuild.nvim' then return spec end
    end
  end

  it('builds Xcode projects on macOS only', function()
    mac = false
    assert.is_false(xcodebuild().cond)
    mac = true
    assert.is_true(xcodebuild().cond)
  end)
end)
