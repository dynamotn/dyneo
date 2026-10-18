local h = require('helpers')

describe('plugins.toolbox.search', function()
  local restores, specs

  --- The spec of `name` among those the file returns
  ---@param name string
  ---@return table
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
    error('no spec ' .. name)
  end

  --- The `lhs` key of `name`, in `mode`
  ---@param name string
  ---@param lhs string
  ---@param mode? string
  ---@return table
  local function key(name, lhs, mode)
    for _, k in ipairs(spec(name).keys) do
      if k[1] == lhs and (mode == nil or k.mode == mode) then return k end
    end
    error('no key ' .. lhs)
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/toolbox/search.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    vim.cmd('silent! %bwipeout!')
  end)

  describe('grug-far', function()
    local opened

    before_each(function()
      table.insert(
        restores,
        h.stub(package.loaded, 'grug-far', {
          open = function(opts) opened = opts end,
        })
      )
    end)

    it('searches the files of the same extension as the buffer', function()
      vim.api.nvim_set_current_buf(h.buffer({ name = '/tmp/dy/a.lua' }))
      key('MagicDuck/grug-far.nvim', '<leader>sr')[2]()
      assert.is_true(opened.transient)
      assert.are.equal('*.lua', opened.prefills.filesFilter)

      vim.api.nvim_set_current_buf(h.buffer({ name = '/tmp/dy/Makefile' }))
      key('MagicDuck/grug-far.nvim', '<leader>sr')[2]()
      assert.is_nil(opened.prefills.filesFilter)

      local scratch = h.buffer({ name = 'term://x.sh' })
      vim.bo[scratch].buftype = 'nofile'
      vim.api.nvim_set_current_buf(scratch)
      key('MagicDuck/grug-far.nvim', '<leader>sr')[2]()
      assert.is_nil(opened.prefills.filesFilter)
    end)

    it('replaces within the file of the buffer', function()
      vim.api.nvim_set_current_buf(h.buffer({ name = '/tmp/dy/a.lua' }))
      key('MagicDuck/grug-far.nvim', '<leader>sf')[2]()
      assert.are.equal(vim.fn.expand('%'), opened.prefills.paths)
    end)
  end)

  describe('trouble', function()
    local trouble, open, notified

    before_each(function()
      open = false
      trouble = {
        is_open = function() return open end,
        prev = function(opts) trouble.moved = { 'prev', opts } end,
        next = function(opts) trouble.moved = { 'next', opts } end,
      }
      table.insert(restores, h.stub(package.loaded, 'trouble', trouble))
      table.insert(
        restores,
        h.stub(
          vim,
          'notify',
          function(msg, level) notified = { msg = msg, level = level } end
        )
      )
    end)

    it('walks the trouble list while it is open', function()
      open = true
      key('folke/trouble.nvim', '[q')[2]()
      assert.same(
        { 'prev', { skip_groups = true, jump = true } },
        trouble.moved
      )
      key('folke/trouble.nvim', ']q')[2]()
      assert.same(
        { 'next', { skip_groups = true, jump = true } },
        trouble.moved
      )
      assert.is_nil(notified)
    end)

    it('walks the quickfix list otherwise, saying when it ends', function()
      local bufnr = h.buffer({ lines = { 'one', 'two' } })
      vim.fn.setqflist({
        { bufnr = bufnr, lnum = 1 },
        { bufnr = bufnr, lnum = 2 },
      })
      vim.fn.setqflist({}, 'a', { idx = 2 })
      key('folke/trouble.nvim', '[q')[2]()
      assert.is_nil(notified)
      assert.are.equal(1, vim.fn.getqflist({ idx = 0 }).idx)
      key('folke/trouble.nvim', '[q')[2]()
      assert.are.equal(vim.log.levels.ERROR, notified.level)
      assert.matches('E553', notified.msg)

      notified = nil
      vim.fn.setqflist({}, 'a', { idx = 2 })
      key('folke/trouble.nvim', ']q')[2]()
      assert.are.equal(vim.log.levels.ERROR, notified.level)
      assert.is_nil(trouble.moved)
    end)
  end)

  describe('todo-comments', function()
    it('jumps between the comments and lists them', function()
      local jumped, listed
      table.insert(
        restores,
        h.stub(package.loaded, 'todo-comments', {
          jump_next = function() jumped = 'next' end,
          jump_prev = function() jumped = 'prev' end,
        })
      )
      table.insert(
        restores,
        h.stub(_G, 'Snacks', {
          picker = { todo_comments = function(opts) listed = opts or {} end },
        })
      )
      key('folke/todo-comments.nvim', ']t')[2]()
      assert.are.equal('next', jumped)
      key('folke/todo-comments.nvim', '[t')[2]()
      assert.are.equal('prev', jumped)
      key('folke/todo-comments.nvim', '<leader>st')[2]()
      assert.same({}, listed)
      key('folke/todo-comments.nvim', '<leader>sT')[2]()
      assert.same({ keywords = { 'TODO', 'FIX', 'FIXME' } }, listed)
      assert.are.equal(
        '<cmd>Trouble todo toggle<cr>',
        key('folke/todo-comments.nvim', '<leader>xt')[2]
      )
    end)
  end)
end)
