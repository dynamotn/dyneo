local h = require('helpers')

describe('plugins.executor.task', function()
  local specs, restores

  ---@param name string
  ---@return table
  local function spec(name)
    for _, plugin in ipairs(specs) do
      if plugin[1] == name then return plugin end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/executor/task.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  describe('restart last task', function()
    local tasks, actions, notified, key

    before_each(function()
      tasks, actions, notified = {}, {}, {}
      restores[#restores + 1] = h.stub(package.loaded, 'overseer', {
        list_tasks = function(opts)
          -- A task that already finished is still the last one run
          assert.is_true(opts.include_ephemeral)
          return tasks
        end,
        run_action = function(task, action)
          table.insert(actions, { task = task, action = action })
        end,
      })
      restores[#restores + 1] = h.stub(
        vim,
        'notify',
        function(msg, level)
          table.insert(notified, { msg = msg, level = level })
        end
      )
      for _, mapping in ipairs(spec('stevearc/overseer.nvim').keys) do
        if mapping[1] == '<leader>ol' then key = mapping[2] end
      end
    end)

    it('restarts the most recent task', function()
      tasks = { { id = 2 }, { id = 1 } }
      key()
      assert.are.same({ { task = { id = 2 }, action = 'restart' } }, actions)
      assert.are.same({}, notified)
    end)

    it('says when there is nothing to restart', function()
      key()
      assert.are.same({}, actions)
      assert.are.same(
        { { msg = 'No task to restart', level = vim.log.levels.WARN } },
        notified
      )
    end)
  end)

  it('lets overseer run the build task of a launch configuration', function()
    local overseer = spec('stevearc/overseer.nvim')
    assert.is_false(overseer.opts.dap)
    local opened = 0
    restores[#restores + 1] = h.stub(
      package.loaded,
      'overseer',
      { enable_dap = function() opened = opened + 1 end }
    )
    spec('mfussenegger/nvim-dap').opts()
    assert.are.equal(1, opened)
  end)

  it('docks the task list on the right of edgy', function()
    local opened = 0
    restores[#restores + 1] = h.stub(
      package.loaded,
      'overseer',
      { open = function() opened = opened + 1 end }
    )
    local opts = {}
    spec('folke/edgy.nvim').opts(nil, opts)
    assert.are.equal(1, #opts.right)
    assert.are.equal('OverseerList', opts.right[1].ft)
    opts.right[1].open()
    assert.are.equal(1, opened)
    -- Added to what other specs put there
    local more = { right = { { ft = 'other' } } }
    spec('folke/edgy.nvim').opts(nil, more)
    assert.are.equal(2, #more.right)
    assert.are.equal('Overseer', more.right[2].title)
  end)

  it('runs the tests through overseer', function()
    local consumer = { name = 'overseer' }
    restores[#restores + 1] =
      h.stub(package.loaded, 'neotest.consumers.overseer', consumer)
    local opts = {}
    spec('nvim-neotest/neotest').opts(nil, opts)
    assert.are.equal(consumer, opts.consumers.overseer)
    local more = { consumers = { trouble = {} } }
    spec('nvim-neotest/neotest').opts(nil, more)
    assert.is_not_nil(more.consumers.trouble)
    assert.are.equal(consumer, more.consumers.overseer)
  end)
end)
