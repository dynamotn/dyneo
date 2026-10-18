local h = require('helpers')

describe('util.project_rtp', function()
  local dir, cleanup, cwd, restores
  before_each(function()
    dir, cleanup = h.tmpdir()
    cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
    restores = {
      -- The working directory is the root for an unnamed buffer anyway
      h.stub(package.loaded, 'util.root', {
        get = function() return vim.fn.getcwd() end,
      }),
    }
    h.unload('util.project_rtp')
  end)
  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    vim.cmd.cd(cwd)
    cleanup()
  end)

  local function load() require('util.project_rtp').setup() end

  it('re-checks the project folder when the directory changes', function()
    load()
    local autocmds = vim.api.nvim_get_autocmds({
      group = 'dy_project_rtp',
      event = 'DirChanged',
    })
    assert.are.equal(1, #autocmds)
  end)

  it('adds a trusted project .nvim folder to the runtimepath', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    table.insert(restores, h.stub(vim.secure, 'read', function() return '' end))
    load()
    assert.is_true(vim.list_contains(vim.opt.rtp:get(), dir .. '/.nvim'))
    vim.opt.rtp:remove(dir .. '/.nvim')
  end)

  it('leaves an untrusted project .nvim folder out', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    table.insert(
      restores,
      h.stub(vim.secure, 'read', function() return nil end)
    )
    load()
    assert.is_false(vim.list_contains(vim.opt.rtp:get(), dir .. '/.nvim'))
    assert.is_nil(require('util.project_rtp').current())
  end)

  it('names the trusted folder it put on the runtimepath', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    table.insert(restores, h.stub(vim.secure, 'read', function() return '' end))
    load()
    assert.equals(dir .. '/.nvim', require('util.project_rtp').current())
    vim.opt.rtp:remove(dir .. '/.nvim')
  end)
  it('puts the folder back once lazy.nvim has reset the runtimepath', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    table.insert(restores, h.stub(vim.secure, 'read', function() return '' end))
    local project_rtp = require('util.project_rtp')
    assert.equals(dir .. '/.nvim', project_rtp.startup_path())
    vim.opt.rtp:remove(dir .. '/.nvim')
    project_rtp.setup()
    assert.is_true(vim.list_contains(vim.opt.rtp:get(), dir .. '/.nvim'))
    -- Already there: not added twice
    project_rtp.setup()
    local count = 0
    for _, path in ipairs(vim.opt.rtp:get()) do
      if path == dir .. '/.nvim' then count = count + 1 end
    end
    assert.equals(1, count)
    vim.opt.rtp:remove(dir .. '/.nvim')
  end)

  it('asks again once the trust database changes', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    local reads, mtime = 0, 1
    local trust = vim.fn.stdpath('state') .. '/trust'
    local fs_stat = vim.uv.fs_stat
    table.insert(
      restores,
      h.stub(vim.uv, 'fs_stat', function(path, ...)
        if path == trust then return { mtime = { sec = mtime, nsec = 0 } } end
        return fs_stat(path, ...)
      end)
    )
    table.insert(
      restores,
      h.stub(vim.secure, 'read', function()
        reads = reads + 1
        return nil
      end)
    )
    local project_rtp = require('util.project_rtp')
    project_rtp.startup_path()
    project_rtp.startup_path()
    assert.are.equal(1, reads)
    mtime = 2
    project_rtp.startup_path()
    assert.are.equal(2, reads)
  end)

  it('drops the folder of this project once :trust takes it back', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    local verdict, mtime = '', 1
    local trust = vim.fn.stdpath('state') .. '/trust'
    local fs_stat = vim.uv.fs_stat
    table.insert(
      restores,
      h.stub(vim.uv, 'fs_stat', function(path, ...)
        if path == trust then return { mtime = { sec = mtime, nsec = 0 } } end
        return fs_stat(path, ...)
      end)
    )
    table.insert(
      restores,
      h.stub(vim.secure, 'read', function() return verdict end)
    )
    local project_rtp = require('util.project_rtp')
    assert.equals(dir .. '/.nvim', project_rtp.startup_path())
    verdict, mtime = nil, 2
    assert.is_nil(project_rtp.startup_path())
    assert.is_false(vim.list_contains(vim.opt.rtp:get(), dir .. '/.nvim'))
  end)

  it('hands lazy.nvim a trusted folder to start with', function()
    vim.fn.mkdir(dir .. '/.nvim', 'p')
    table.insert(restores, h.stub(vim.secure, 'read', function() return '' end))
    assert.are.equal(
      dir .. '/.nvim',
      require('util.project_rtp').startup_path()
    )
    vim.opt.rtp:remove(dir .. '/.nvim')
  end)

  it(
    'hands lazy.nvim nothing without a trusted folder',
    function() assert.is_nil(require('util.project_rtp').startup_path()) end
  )
end)
