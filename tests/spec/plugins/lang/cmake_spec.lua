local h = require('helpers')

describe('plugins.lang.cmake', function()
  local restores, loaded, dir, cleanup

  before_each(function()
    h.globals()
    loaded = {}
    dir, cleanup = h.tmpdir()
    restores = {
      h.stub(package.loaded, 'lazy', {
        load = function(opts) vim.list_extend(loaded, opts.plugins) end,
      }),
    }
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/cmake.lua')) do
      if spec[1] == 'Civitasv/cmake-tools.nvim' then spec.init() end
    end
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'dyneo_cmake')
    cleanup()
  end)

  it('waits for a held directory, then loads for its buffers', function()
    -- The module `init` registered its release starter with
    local untrusted = require('util.untrusted')
    h.write(dir .. '/proj/CMakeLists.txt')
    untrusted.hold(dir .. '/proj')
    h.buffer({ name = dir .. '/proj/src/main.cpp', filetype = 'cpp' })
    assert.same({}, loaded)
    untrusted.release(dir .. '/proj')
    assert.same({ 'cmake-tools.nvim' }, loaded)
  end)

  it('loads nothing for another file of a directory let go', function()
    local untrusted = require('util.untrusted')
    h.write(dir .. '/proj/CMakeLists.txt')
    untrusted.hold(dir .. '/proj')
    h.buffer({ name = dir .. '/proj/README.md', filetype = 'markdown' })
    untrusted.release(dir .. '/proj')
    assert.same({}, loaded)
    vim.cmd('silent! %bwipeout!')
  end)

  it('loads cmake-tools for a file of a CMake project', function()
    h.write(dir .. '/proj/CMakeLists.txt')
    h.buffer({ name = dir .. '/other/x.c', filetype = 'c' })
    assert.same({}, loaded)
    h.buffer({ name = dir .. '/proj/src/main.cpp', filetype = 'cpp' })
    assert.same({ 'cmake-tools.nvim' }, loaded)
    -- Once is enough
    h.buffer({ name = dir .. '/proj/src/util.c', filetype = 'c' })
    assert.same({ 'cmake-tools.nvim' }, loaded)
  end)
end)
