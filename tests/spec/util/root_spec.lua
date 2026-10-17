local h = require('helpers')

describe('util.root', function()
  local root, dir, cleanup, cwd, restore_spec
  before_each(function()
    dir, cleanup = h.tmpdir()
    cwd = vim.fn.getcwd()
    restore_spec = h.stub(vim.g, 'root_spec', nil)
    h.unload('util.root')
    root = require('util.root')
  end)
  after_each(function()
    restore_spec()
    vim.cmd('silent! %bwipeout!')
    vim.cmd.cd(cwd)
    cleanup()
  end)

  it('resolves the working directory once until it changes', function()
    vim.cmd.cd(dir)
    local calls = 0
    local realpath = vim.uv.fs_realpath
    local restore = h.stub(vim.uv, 'fs_realpath', function(...)
      calls = calls + 1
      return realpath(...)
    end)
    root.cwd()
    root.cwd()
    vim.fn.mkdir(dir .. '/sub', 'p')
    vim.cmd.cd(dir .. '/sub')
    local sub = root.cwd()
    restore()
    assert.equals(2, calls)
    assert.equals(realpath(dir .. '/sub'), sub)
  end)

  it('finds the nearest directory holding a marker', function()
    h.write(dir .. '/project/.git/HEAD', { 'ref: refs/heads/main' })
    h.write(dir .. '/project/src/deep/file.lua', { '' })
    vim.cmd.edit(dir .. '/project/src/deep/file.lua')
    assert.are.equal(dir .. '/project', root.get())
    assert.are.equal(dir .. '/project', root())
  end)

  it('falls back to the working directory', function()
    vim.cmd.cd(dir)
    h.write(dir .. '/file.txt', { '' })
    vim.cmd.edit(dir .. '/file.txt')
    assert.are.equal(dir, root.get())
  end)

  it('follows vim.g.root_spec', function()
    h.write(dir .. '/a/marker.txt', { '' })
    h.write(dir .. '/a/b/.git/HEAD', { '' })
    h.write(dir .. '/a/b/c.lua', { '' })
    vim.g.root_spec = { 'marker.txt' }
    vim.cmd.edit(dir .. '/a/b/c.lua')
    assert.are.equal(dir .. '/a', root.get())
  end)

  it('caches the root per buffer', function()
    h.write(dir .. '/x/.git/HEAD', { '' })
    h.write(dir .. '/x/y.lua', { '' })
    vim.cmd.edit(dir .. '/x/y.lua')
    local buf = vim.api.nvim_get_current_buf()
    assert.are.equal(dir .. '/x', root.get())
    root.cache[buf] = '/cached'
    assert.are.equal('/cached', root.get())
  end)

  it('tells a directory from a sibling sharing its prefix', function()
    assert.is_true(root.contains('/x/proj', '/x/proj'))
    assert.is_true(root.contains('/x/proj', '/x/proj/f.lua'))
    assert.is_true(root.contains('/', '/x/f.lua'))
    assert.is_false(root.contains('/x/proj', '/x/proj-other/f.lua'))
    assert.is_false(root.contains('/x/proj', '/x/pro'))
  end)

  describe('lsp detector', function()
    local restore_clients
    after_each(function() restore_clients() end)

    --- Stub the clients of every buffer
    local function clients(list)
      restore_clients = h.stub(
        vim.lsp,
        'get_clients',
        function() return list end
      )
    end

    it('skips a client rooted at a sibling of the file', function()
      h.write(dir .. '/proj-other/f.lua', { '' })
      vim.cmd.edit(dir .. '/proj-other/f.lua')
      clients({ { name = 'lua_ls', root_dir = dir .. '/proj', config = {} } })
      assert.same({}, root.detectors.lsp(0))
    end)

    it('keeps a client rooted at a symlink to the project', function()
      h.write(dir .. '/real/f.lua', { '' })
      assert(vim.uv.fs_symlink(dir .. '/real', dir .. '/link'))
      vim.cmd.edit(dir .. '/link/f.lua')
      clients({ { name = 'lua_ls', root_dir = dir .. '/link', config = {} } })
      assert.same({ dir .. '/link' }, root.detectors.lsp(0))
    end)

    it('takes the workspace folders added since the client started', function()
      h.write(dir .. '/ws/added/f.lua', { '' })
      vim.cmd.edit(dir .. '/ws/added/f.lua')
      clients({
        {
          name = 'lua_ls',
          root_dir = dir .. '/elsewhere',
          workspace_folders = {
            { uri = vim.uri_from_fname(dir .. '/ws/added'), name = 'added' },
          },
          config = { workspace_folders = {} },
        },
      })
      assert.same({ dir .. '/ws/added' }, root.detectors.lsp(0))
    end)
  end)

  it('gives the git work tree around the root', function()
    h.write(dir .. '/repo/.git/HEAD', { '' })
    h.write(dir .. '/repo/sub/lua/mod.lua', { '' })
    vim.g.root_spec = { 'lua' }
    vim.cmd.edit(dir .. '/repo/sub/lua/mod.lua')
    assert.are.equal(dir .. '/repo/sub', root.get())
    assert.are.equal(dir .. '/repo', root.git())
  end)

  it('takes the root of an attached client', function()
    h.write(dir .. '/ws/src/a.lua', { '' })
    vim.cmd.edit(dir .. '/ws/src/a.lua')
    local restore = h.stub(vim.lsp, 'get_clients', function()
      return {
        { name = 'lua_ls', root_dir = dir .. '/ws', config = {} },
        -- Ignored by `vim.g.root_lsp_ignore`
        { name = 'copilot', root_dir = dir, config = {} },
      }
    end)
    local ignore = h.stub(vim.g, 'root_lsp_ignore', { 'copilot' })
    assert.are.same({ dir .. '/ws' }, root.detectors.lsp(0))
    ignore()
    restore()
  end)

  it('forgets a cached root once setup runs and a buffer is entered', function()
    h.write(dir .. '/y/.git/HEAD', { '' })
    h.write(dir .. '/y/z.lua', { '' })
    vim.cmd.edit(dir .. '/y/z.lua')
    local buf = vim.api.nvim_get_current_buf()
    root.cache[buf] = '/stale'
    root.setup()
    assert.is_nil(root.cache[buf])
    root.cache[buf] = '/stale'
    vim.api.nvim_exec_autocmds('BufEnter', { buffer = buf })
    assert.is_nil(root.cache[buf])
    -- A server gone, or the buffer renamed, may change the root as well
    for _, event in ipairs({ 'LspDetach', 'BufFilePost' }) do
      root.cache[buf] = '/stale'
      vim.api.nvim_exec_autocmds(event, { buffer = buf, modeline = false })
      assert.is_nil(root.cache[buf], event)
    end
    assert.is_not_nil(vim.api.nvim_get_commands({}).DyRoot)
  end)

  it('reports every root found, the one in use first', function()
    h.write(dir .. '/r/.git/HEAD', { '' })
    h.write(dir .. '/r/lua/m.lua', { '' })
    vim.cmd.edit(dir .. '/r/lua/m.lua')
    local shown
    local restore = h.stub(
      require('util.plugin'),
      'info',
      function(lines) shown = lines end
    )
    assert.are.equal(dir .. '/r', root.info())
    restore()
    assert.truthy(shown[1]:find('[x] `' .. dir .. '/r`', 1, true))
  end)
end)
