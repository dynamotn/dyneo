local h = require('helpers')

describe('plugins.lang.python', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.python` returns
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/lang/python.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  describe('venv-selector', function()
    local synced, asked, answer

    before_each(function()
      synced, asked, answer = {}, 0, 1
      local uv2 = {
        is_uv_buffer = function(bufnr) return vim.b[bufnr].pep723 == true end,
        run_uv_flow_if_needed = function(bufnr) table.insert(synced, bufnr) end,
      }
      table.insert(
        restores,
        h.stub(package.loaded, 'venv-selector', { setup = function() end })
      )
      table.insert(restores, h.stub(package.loaded, 'venv-selector.uv2', uv2))
      table.insert(
        restores,
        h.stub(vim.fn, 'confirm', function()
          asked = asked + 1
          return answer
        end)
      )
      spec('linux-cultist/venv-selector.nvim').config(nil, {})
    end)

    it('syncs a script declaring dependencies only once agreed to', function()
      local uv2 = require('venv-selector.uv2')
      local bufnr = h.buffer({ name = 'x.py' })
      vim.b[bufnr].pep723 = true
      answer = 2
      uv2.run_uv_flow_if_needed(bufnr)
      uv2.run_uv_flow_if_needed(bufnr)
      assert.same({}, synced)
      assert.equal(1, asked)

      local other = h.buffer({ name = 'y.py' })
      vim.b[other].pep723 = true
      answer = 1
      uv2.run_uv_flow_if_needed(other)
      uv2.run_uv_flow_if_needed(other)
      assert.same({ other, other }, synced)
      assert.equal(2, asked)
    end)

    it('leaves a plain file alone without asking', function()
      local bufnr = h.buffer({ name = 'z.py' })
      require('venv-selector.uv2').run_uv_flow_if_needed(bufnr)
      assert.same({ bufnr }, synced)
      assert.equal(0, asked)
    end)

    it('takes the current buffer when asked about none', function()
      local bufnr = h.buffer({ name = 'w.py' })
      vim.api.nvim_set_current_buf(bufnr)
      require('venv-selector.uv2').run_uv_flow_if_needed(nil)
      require('venv-selector.uv2').run_uv_flow_if_needed(0)
      assert.same({ bufnr, bufnr }, synced)
      -- A buffer gone by the time it runs
      vim.api.nvim_buf_delete(bufnr, { force = true })
      assert.is_nil(require('venv-selector.uv2').run_uv_flow_if_needed(bufnr))
      assert.are.equal(2, #synced)
    end)
  end)

  it('starts IPython when the environment has it', function()
    table.insert(
      restores,
      h.stub(package.loaded, 'iron.fts.common', {
        bracketed_paste_python = function(_, extras) return extras.command end,
      })
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'iron.view', {
        split = { vertical = { botright = function() end } },
      })
    )
    table.insert(
      restores,
      h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'ipython' and 1 or 0 end
      )
    )
    local python =
      spec('Vigemus/iron.nvim').opts().config.repl_definition.python
    assert.same({ 'ipython', '--no-autoindent' }, python.command())
    assert.same({ 'ipython', '--no-autoindent' }, python.format({ 'x' }, {}))
  end)

  it('pastes in the format of the REPL that was started', function()
    local seen
    table.insert(
      restores,
      h.stub(package.loaded, 'iron.fts.common', {
        bracketed_paste_python = function(_, extras)
          seen = extras.command
          return {}
        end,
      })
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'iron.view', {
        split = { vertical = { botright = function() end } },
      })
    )
    local python =
      spec('Vigemus/iron.nvim').opts().config.repl_definition.python
    local has_ipython = false
    table.insert(
      restores,
      h.stub(
        vim.fn,
        'executable',
        function(name) return (name == 'ipython' and has_ipython) and 1 or 0 end
      )
    )
    python.command()
    -- A venv holding IPython is picked after the REPL started
    has_ipython = true
    python.format({ 'x = 1' }, { command = python.command })
    assert.same({ 'python3' }, seen)
  end)
end)
