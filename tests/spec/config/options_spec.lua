local h = require('helpers')

describe('config.options', function()
  local dir, cleanup, cwd, restores
  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    cwd = vim.fn.getcwd()
    vim.cmd.cd(dir)
    -- Root detection wants lazy.nvim set up; the working directory is the
    -- root it would find for an unnamed buffer anyway
    restores = {
      h.stub(package.loaded, 'util.root', {
        get = function() return vim.fn.getcwd() end,
      }),
    }
  end)
  after_each(function()
    for _, restore in ipairs(restores) do
      restore()
    end
    vim.cmd.cd(cwd)
    cleanup()
  end)

  local function load() dofile(h.root .. '/lua/config/options.lua') end

  it('sets the editor options', function()
    load()
    assert.are.equal('80,120', vim.o.colorcolumn)
    assert.is_true(vim.o.backup)
    assert.are.equal(vim.fn.stdpath('state') .. '/backup//', vim.o.backupdir)
    assert.are.equal(2, vim.o.modelines)
    assert.is_true(vim.o.wrap)
    assert.is_nil(vim.o.mouse:find('a', 1, true))
    assert.are.same(
      { 'en_us', 'vi', 'proper', 'technical' },
      vim.opt.spelllang:get()
    )
  end)

  it('turns off the non-Lua providers', function()
    load()
    for _, provider in ipairs({ 'python3', 'perl', 'ruby', 'node' }) do
      assert.are.equal(0, vim.g['loaded_' .. provider .. '_provider'])
    end
  end)

  it('sets the background from dark_mode', function()
    DyNeo.dark_mode = false
    load()
    assert.are.equal('light', vim.o.background)
    DyNeo.dark_mode = true
    load()
    assert.are.equal('dark', vim.o.background)
  end)

  it('installs the insert mode abbreviations', function()
    load()
    for abbr in pairs(require('config.defaults').abbreviations) do
      assert.is_not_nil(vim.fn.maparg(abbr, 'i', true, true).callback, abbr)
    end
  end)

  it('expands the abbreviations in a comment of code', function()
    load()
    local expand = vim.fn.maparg('gh', 'i', true, true).callback
    local bufnr = h.buffer({ lines = { '-- gh', 'gh' } })
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'lua'
    local captures = {}
    table.insert(
      restores,
      h.stub(
        vim.treesitter,
        'get_captures_at_pos',
        function() return captures end
      )
    )
    vim.api.nvim_win_set_cursor(0, { 1, 5 })
    assert.are.equal('gh', expand())
    captures = { { capture = 'comment.line' } }
    assert.are.equal('https://github.com/', expand())
    captures = { { capture = 'string' } }
    assert.are.equal('gh', expand())
  end)

  it('expands the abbreviations in prose only', function()
    load()
    local expand = vim.fn.maparg('gh', 'i', true, true).callback
    local bufnr = h.buffer({ lines = { 'gh' } })
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = 'markdown'
    assert.are.equal('https://github.com/', expand())
    vim.bo[bufnr].filetype = 'sh'
    assert.are.equal('gh', expand())
  end)
end)
