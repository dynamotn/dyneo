local h = require('helpers')

--- The spec of `name` in `plugins/integration/other.lua`
---@param name string
---@return table
local function spec_of(name)
  for _, plugin in
    ipairs(dofile(h.root .. '/lua/plugins/integration/other.lua'))
  do
    if plugin[1] == name then return plugin end
  end
  error('no spec for ' .. name)
end

describe('plugins.integration.other: flatten.nvim', function()
  local hooks, restores, blocked_upstream, terminal

  before_each(function()
    blocked_upstream = false
    terminal = nil
    restores = {
      h.stub(package.loaded, 'flatten', {
        hooks = {
          should_block = function() return blocked_upstream end,
        },
      }),
      h.stub(package.loaded, 'toggleterm.terminal', {
        get_focused_id = function() return terminal and 1 or nil end,
        get = function() return terminal end,
      }),
    }
    hooks = spec_of('willothy/flatten.nvim').opts().hooks
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('waits for a temporary file, as upstream does for a commit', function()
    assert.is_false(hooks.should_block({ '--clean', '/home/me/notes.md' }))
    assert.is_true(hooks.should_block({ '-u', 'NONE', '/tmp/x/edit.txt' }))
    assert.is_true(hooks.should_block({ '/private/var/folders/ab/e.txt' }))
    local tmpdir = vim.fs.normalize(vim.uv.os_tmpdir() or '/nowhere')
    assert.is_true(hooks.should_block({ tmpdir .. '/edit.txt' }))
    -- A flag is never a path
    assert.is_false(hooks.should_block({ '--/tmp' }))
    blocked_upstream = true
    assert.is_true(hooks.should_block({ '/home/me/notes.md' }))
  end)

  it('closes the toggleterm the files came from, and reopens it', function()
    local closed, opened = 0, 0
    terminal = {
      close = function() closed = closed + 1 end,
      open = function() opened = opened + 1 end,
    }
    hooks.pre_open()
    local bufnr = h.buffer({ lines = { 'x' } })
    hooks.post_open({ bufnr = bufnr, winnr = 0, is_blocking = false })
    assert.equals(1, closed)
    -- Nothing to reopen once a run that did not block is over
    hooks.block_end()
    vim.wait(50, function() return false end, 5)
    assert.equals(0, opened)

    hooks.pre_open()
    hooks.post_open({
      bufnr = bufnr,
      winnr = vim.api.nvim_get_current_win(),
      is_blocking = true,
    })
    assert.equals(2, closed)
    hooks.block_end()
    vim.wait(200, function() return opened == 1 end, 5)
    assert.equals(1, opened)
  end)

  it(
    'hides a floating window, keeps a split, and drops the buffer written',
    function()
      local float = vim.api.nvim_open_win(h.buffer({}), true, {
        relative = 'editor',
        row = 1,
        col = 1,
        width = 10,
        height = 3,
      })
      hooks.pre_open()
      local bufnr = h.buffer({ lines = { 'x' } })
      local deleted
      local restore = h.stub(_G, 'Snacks', {
        bufdelete = function(opts) deleted = opts.buf end,
      })
      hooks.post_open({
        bufnr = bufnr,
        winnr = vim.api.nvim_get_current_win(),
        is_blocking = true,
      })
      assert.is_false(vim.api.nvim_win_is_valid(float))
      vim.api.nvim_exec_autocmds('BufWritePost', { buffer = bufnr })
      vim.wait(200, function() return deleted ~= nil end, 5)
      restore()
      assert.equals(bufnr, deleted)

      -- A split terminal stays where it is
      vim.cmd.split()
      local split = vim.api.nvim_get_current_win()
      hooks.pre_open()
      hooks.post_open({ bufnr = bufnr, winnr = nil, is_blocking = false })
      assert.is_true(vim.api.nvim_win_is_valid(split))
    end
  )

  it('copes without toggleterm, and with a window gone', function()
    restores[2]()
    local restore = h.stub(package.loaded, 'toggleterm.terminal', nil)
    local preload = h.stub(
      package.preload,
      'toggleterm.terminal',
      function() error('not installed') end
    )
    vim.cmd.split()
    hooks.pre_open()
    vim.cmd.close()
    assert.has_no.errors(
      function() hooks.post_open({ bufnr = 0, winnr = 0, is_blocking = false }) end
    )
    preload()
    restore()
    restores[2] = function() end
  end)
end)

describe('plugins.integration.other: im-switch options', function()
  local restore, has_fcitx

  before_each(function()
    local executable = vim.fn.executable
    restore = h.stub(vim.fn, 'executable', function(name)
      if name == 'fcitx5-remote' then return has_fcitx and 1 or 0 end
      return executable(name)
    end)
  end)
  after_each(function() restore() end)

  it('hands fcitx5 over only when its command is there', function()
    has_fcitx = false
    local opts = spec_of('drop-stones/im-switch.nvim').opts()
    assert.is_nil(opts.linux)
    assert.is_string(opts.macos.default_im)

    has_fcitx = true
    opts = spec_of('drop-stones/im-switch.nvim').opts()
    assert.same({ 'fcitx5-remote', '-q' }, opts.linux.get_im_command)
    assert.equals('English', opts.linux.default_im)
  end)
end)
