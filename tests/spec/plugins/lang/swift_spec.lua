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

  it('debugs a SwiftPM build through codelldb', function()
    local dap = { adapters = {}, configurations = {} }
    local restores = {
      h.stub(package.loaded, 'dap', dap),
      h.stub(package.loaded, 'dap.utils', { pick_process = 'pick' }),
      h.stub(vim.fn, 'input', function(_, default) return default end),
    }
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/swift.lua')) do
      if spec[1] == 'mfussenegger/nvim-dap' then spec.opts() end
      if spec[1] == 'jay-babu/mason-nvim-dap.nvim' then
        assert.is_nil(spec.opts.handlers.codelldb())
      end
    end
    assert.are.equal('codelldb', dap.adapters.codelldb.executable.command)
    local launch, attach = unpack(dap.configurations.swift)
    assert.are.equal(vim.fn.getcwd() .. '/.build/debug/', launch.program())
    assert.are.equal('pick', attach.pid)
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)
end)
