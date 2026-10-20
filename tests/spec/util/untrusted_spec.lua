local h = require('helpers')

describe('util.untrusted', function()
  local untrusted, dir, cleanup, restores

  before_each(function()
    h.unload('util.untrusted')
    untrusted = require('util.untrusted')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/wt/src', 'p')
    vim.fn.mkdir(dir .. '/wt-other', 'p')
    restores = {}
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('holds a buffer under the directory and not a sibling', function()
    untrusted.hold(dir .. '/wt')
    local inside = h.buffer({ name = dir .. '/wt/src/a.lua' })
    local sibling = h.buffer({ name = dir .. '/wt-other/a.lua' })
    assert.is_true(untrusted.held(inside))
    assert.is_false(untrusted.held(sibling))
    assert.is_true(untrusted.held(dir .. '/wt'))
    assert.is_true(untrusted.held(dir .. '/wt/src/new-file.lua'))
    assert.is_false(untrusted.held(dir .. '/wt-other'))
    assert.is_false(untrusted.held(dir))
    -- An unnamed buffer lives nowhere
    assert.is_false(untrusted.held(h.buffer()))
  end)

  it('knows a held directory by its real path', function()
    vim.uv.fs_symlink(dir .. '/wt', dir .. '/link')
    untrusted.hold(dir .. '/link/')
    assert.is_true(untrusted.held(dir .. '/wt/src'))
    untrusted.forget(dir .. '/wt')
    assert.is_false(untrusted.held(dir .. '/link/src'))
  end)

  it('calls on_first once for many buffers', function()
    local seen = {}
    untrusted.hold(dir .. '/wt', function(bufnr) table.insert(seen, bufnr) end)
    local first = h.buffer({ name = dir .. '/wt/a.lua' })
    local second = h.buffer({ name = dir .. '/wt/b.lua' })
    assert.is_true(untrusted.held(first))
    assert.is_true(untrusted.held(second))
    -- Scheduled, not run from inside the server's `root_dir`
    assert.same({}, seen)
    vim.wait(200, function() return #seen > 0 end)
    untrusted.held(first)
    vim.wait(50)
    assert.same({ first }, seen)
  end)

  it('release reruns only the lsp enable group', function()
    local group = vim.api.nvim_create_augroup('nvim.lsp.enable', {})
    vim.api.nvim_create_autocmd('FileType', {
      group = group,
      callback = function() end,
    })
    local runs = {}
    table.insert(
      restores,
      function() pcall(vim.api.nvim_del_augroup_by_name, 'nvim.lsp.enable') end
    )
    table.insert(
      restores,
      h.stub(
        vim.api,
        'nvim_exec_autocmds',
        function(event, opts) table.insert(runs, { event, opts }) end
      )
    )
    untrusted.hold(dir .. '/wt')
    local inside = h.buffer({ name = dir .. '/wt/a.lua' })
    h.buffer({ name = dir .. '/wt-other/a.lua' })
    untrusted.release(dir .. '/wt')
    assert.same(
      { { 'FileType', { group = 'nvim.lsp.enable', buffer = inside } } },
      runs
    )
    assert.is_false(untrusted.held(inside))
  end)

  it('release starts what a plugin starts itself, once per name', function()
    local started, errors = {}, {}
    table.insert(
      restores,
      h.stub(vim, 'notify', function(msg) table.insert(errors, msg) end)
    )
    untrusted.on_release('a', function() table.insert(started, 'replaced') end)
    untrusted.on_release(
      'a',
      function(bufnr) table.insert(started, { 'a', bufnr }) end
    )
    untrusted.on_release('b', function() error('broken') end)
    untrusted.on_release(
      'c',
      function(bufnr) table.insert(started, { 'c', bufnr }) end
    )
    untrusted.hold(dir .. '/wt')
    local inside = h.buffer({ name = dir .. '/wt/a.lua' })
    h.buffer({ name = dir .. '/wt-other/a.lua' })
    untrusted.release(dir .. '/wt')
    -- A starter that fails says so and does not stop the others
    assert.same({ { 'a', inside }, { 'c', inside } }, started)
    assert.equals(1, #errors)
    assert.matches('Could not start b', errors[1])
  end)

  it('forget lets go without starting anything', function()
    local runs = 0
    table.insert(
      restores,
      h.stub(vim.api, 'nvim_exec_autocmds', function() runs = runs + 1 end)
    )
    untrusted.on_release('a', function() runs = runs + 1 end)
    untrusted.hold(dir .. '/wt')
    local inside = h.buffer({ name = dir .. '/wt/a.lua' })
    untrusted.forget(dir .. '/wt')
    assert.is_false(untrusted.held(inside))
    assert.equals(0, runs)
  end)

  it('held answers false fast when nothing is held', function()
    local function boom() error('looked further than the holds') end
    table.insert(restores, h.stub(vim.uv, 'fs_realpath', boom))
    table.insert(restores, h.stub(vim.api, 'nvim_buf_get_name', boom))
    assert.is_false(untrusted.held(1))
    assert.is_false(untrusted.held('/x/wt/a.lua'))
  end)
end)
