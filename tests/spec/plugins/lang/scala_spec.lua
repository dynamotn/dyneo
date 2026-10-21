local h = require('helpers')

describe('plugins.lang.scala', function()
  local restores, attached, dir, cleanup, metals

  before_each(function()
    h.globals()
    attached = {}
    dir, cleanup = h.tmpdir()
    restores = {
      h.stub(package.loaded, 'metals', {
        initialize_or_attach = function()
          table.insert(attached, vim.api.nvim_get_current_buf())
        end,
      }),
    }
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/scala.lua')) do
      if spec[1] == 'scalameta/nvim-metals' then metals = spec end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dy_metals')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('loads with a Scala file, not with a Java one', function()
    assert.is_true(vim.list_contains(metals.ft, 'scala'))
    assert.is_false(vim.list_contains(metals.ft, 'java'))
  end)

  it('configures metals with the status bar off and DAP on attach', function()
    local set_up = false
    local module = require('metals')
    module.bare_config = function() return { init_options = {} } end
    module.setup_dap = function() set_up = true end
    local config = metals.opts()
    assert.are.equal('off', config.init_options.statusBarProvider)
    assert.is_true(config.settings.verboseCompilation)
    assert.are.equal('Test Explorer', config.settings.testUserInterface)
    config.on_attach(nil, nil)
    assert.is_true(set_up)
  end)

  it('debugs through metals rather than an adapter of its own', function()
    local dap = { configurations = {} }
    table.insert(restores, h.stub(package.loaded, 'dap', dap))
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/scala.lua')) do
      if spec[1] == 'mfussenegger/nvim-dap' then spec.opts() end
    end
    assert.are.equal(2, #dap.configurations.scala)
    assert.are.equal(
      'runOrTestFile',
      dap.configurations.scala[1].metals.runType
    )
    assert.are.equal('testTarget', dap.configurations.scala[2].metals.runType)
  end)

  it('holds metals off a held buffer until released', function()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    table.insert(restores, function() untrusted.forget(dir) end)
    untrusted.hold(dir .. '/sbt')
    metals.config(metals, {})
    h.write(dir .. '/sbt/build.sbt')
    local scala = h.buffer({ name = dir .. '/sbt/src/A.scala' })
    vim.api.nvim_set_current_buf(scala)
    vim.bo[scala].filetype = 'scala'
    h.buffer({ name = dir .. '/sbt/README.md', filetype = 'markdown' })
    assert.same({}, attached)
    untrusted.release(dir .. '/sbt')
    assert.same({ scala }, attached)
  end)

  it('takes the Java sources of a Scala build once running', function()
    metals.config(metals, {})
    h.write(dir .. '/sbt/build.sbt')
    local java = h.buffer({ name = dir .. '/sbt/src/A.java' })
    vim.api.nvim_set_current_buf(java)
    vim.bo[java].filetype = 'java'
    local plain = h.buffer({ name = dir .. '/maven/src/B.java' })
    vim.api.nvim_set_current_buf(plain)
    vim.bo[plain].filetype = 'java'
    assert.same({ java }, attached)
  end)
end)
