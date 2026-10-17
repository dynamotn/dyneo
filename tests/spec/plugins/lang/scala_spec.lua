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
