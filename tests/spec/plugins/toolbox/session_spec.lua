local h = require('helpers')

describe('plugins.toolbox.session', function()
  local restore, calls, persistence

  before_each(function()
    h.globals()
    calls = {}
    restore = h.stub(
      package.loaded,
      'persistence',
      setmetatable({}, {
        __index = function(_, name)
          return function(opts) table.insert(calls, { name, opts }) end
        end,
      })
    )
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/session.lua')) do
      if spec[1] == 'folke/persistence.nvim' then persistence = spec end
    end
  end)
  after_each(function() restore() end)

  it('restores, selects and stops the session from the quit group', function()
    assert.are.equal('BufReadPre', persistence.event)
    for _, key in ipairs(persistence.keys) do
      key[2]()
    end
    assert.same({
      { 'load' },
      { 'select' },
      { 'load', { last = true } },
      { 'stop' },
    }, calls)
    assert.are.equal('<leader>qd', persistence.keys[4][1])
  end)

  describe('before it is saved', function()
    after_each(function()
      vim.cmd('silent! tabonly!')
      vim.cmd('silent! %bwipeout!')
    end)

    --- A new tab showing a buffer named `name`, of `buftype`
    ---@param name string
    ---@param buftype string
    ---@return integer tab, integer bufnr
    local function tab(name, buftype)
      vim.cmd.tabnew()
      local bufnr = vim.api.nvim_get_current_buf()
      vim.bo[bufnr].buftype = buftype
      vim.api.nvim_buf_set_name(bufnr, name)
      return vim.api.nvim_get_current_tabpage(), bufnr
    end

    it('lets go of the tool tabs, and keeps the files and help', function()
      persistence.init()
      local file_tab = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_buf_set_name(0, vim.fn.tempname() .. '.lua')
      local tool_tab, tool = tab('dyproject:///x/proj', 'nofile')
      local help_tab = tab('help.txt', 'help')
      vim.api.nvim_exec_autocmds('User', { pattern = 'PersistenceSavePre' })
      assert.same({ file_tab, help_tab }, vim.api.nvim_list_tabpages())
      assert.is_false(vim.api.nvim_tabpage_is_valid(tool_tab))
      assert.is_false(vim.api.nvim_buf_is_valid(tool))
    end)

    it('keeps the last tab, even of tools', function()
      persistence.init()
      vim.cmd('silent! tabonly!')
      vim.bo.buftype = 'nofile'
      vim.api.nvim_exec_autocmds('User', { pattern = 'PersistenceSavePre' })
      assert.are.equal(1, #vim.api.nvim_list_tabpages())
    end)
  end)
end)
