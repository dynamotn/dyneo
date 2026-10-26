local h = require('helpers')

describe('tools.diagram.mermaid', function()
  local dir, cleanup, cache_dir, commands, executables, results, notified
  local inputs, restores, mermaid

  --- Run `fn` with `tbl[key]` replaced for the rest of the test
  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    restores = {}
    dir, cleanup = h.tmpdir()
    cache_dir = dir .. '/cache/diagram-cache/mermaid'
    commands, notified, inputs = {}, {}, {}
    executables = { mmdc = 1 }
    -- Exit code of each command, by its program
    results = {}

    local stdpath = vim.fn.stdpath
    stub(vim.fn, 'stdpath', function(what)
      if what == 'cache' then return dir .. '/cache' end
      return stdpath(what)
    end)
    stub(vim.fn, 'executable', function(name) return executables[name] or 0 end)
    stub(
      vim,
      'system',
      h.system_double(function(cmd)
        table.insert(commands, cmd)
        if cmd[1] == 'mmdc' then
          -- What mmdc was given, read while it still exists
          table.insert(inputs, vim.fn.readfile(cmd[3]))
        end
        return results[cmd[1]] or { code = 0, stderr = '' }
      end)
    )
    stub(
      vim,
      'notify',
      function(msg, level, opts)
        table.insert(notified, { msg = msg, level = level, title = opts.title })
      end
    )
    stub(vim.env, 'ZELLIJ', '0')
    stub(vim.env, 'KITTY_LISTEN_ON', 'unix:/tmp/kitty')
    executables.kitten = 1

    h.unload('tools.diagram.mermaid', 'tools.diagram.d2.snacks')
    mermaid = require('tools.diagram.mermaid')
  end)

  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  ---@param program string
  local function command_of(program)
    for _, cmd in ipairs(commands) do
      if cmd[1] == program then return cmd end
    end
  end

  --- Open a buffer holding `lines`, put the cursor on `row` and preview
  ---@param lines string[]
  ---@param row integer
  ---@param filetype? string
  local function preview(lines, row, filetype)
    local bufnr = h.buffer({ lines = lines })
    vim.bo[bufnr].filetype = filetype or 'markdown'
    vim.api.nvim_set_current_buf(bufnr)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    mermaid.preview(bufnr)
    vim.wait(100, function() return false end)
  end

  local doc = {
    '# Title',
    '',
    '```mermaid',
    'graph TD',
    '  a --> b',
    '```',
    '',
    '```sh',
    'echo hi',
    '```',
  }

  describe('block_at', function()
    it('finds the mermaid block around a row, fences included', function()
      for _, row in ipairs({ 3, 4, 5, 6 }) do
        assert.are.same({ 'graph TD', '  a --> b' }, mermaid.block_at(doc, row))
      end
    end)

    it('finds nothing outside a block or in another language', function()
      assert.is_nil(mermaid.block_at(doc, 1))
      assert.is_nil(mermaid.block_at(doc, 7))
      assert.is_nil(mermaid.block_at(doc, 9))
    end)

    it('reads a tilde fence and an unclosed block', function()
      assert.are.same(
        { 'pie' },
        mermaid.block_at({ '~~~ mermaid', 'pie', '~~~' }, 2)
      )
      assert.are.same({ 'pie' }, mermaid.block_at({ '```mermaid', 'pie' }, 2))
    end)

    it('does not close a fence on a shorter one', function()
      local lines = { '````mermaid', '```', 'pie', '````' }
      assert.are.same({ '```', 'pie' }, mermaid.block_at(lines, 3))
    end)
  end)

  it('renders the block under the cursor in a kitty overlay', function()
    preview(doc, 4)
    assert.are.same({ { 'graph TD', '  a --> b' } }, inputs)
    local mmdc = command_of('mmdc')
    assert.are.equal('-o', mmdc[4])
    assert.is_truthy(mmdc[5]:match('%.png$'))
    assert.are.same({
      'kitten',
      '@',
      '--to',
      'unix:/tmp/kitty',
      'launch',
      '--type=overlay',
      '--title=Mermaid preview',
    }, vim.list_slice(command_of('kitten'), 1, 7))
    -- The input is not left in the cache
    assert.are.same({}, vim.fn.glob(cache_dir .. '/*.mmd', true, true))
  end)

  it('renders a whole mermaid file', function()
    preview({ 'graph LR', '  x --> y' }, 1, 'mermaid')
    assert.are.same({ { 'graph LR', '  x --> y' } }, inputs)
  end)

  it('says so when the cursor is in no diagram', function()
    preview(doc, 9)
    assert.is_nil(command_of('mmdc'))
    assert.are.equal(vim.log.levels.WARN, notified[1].level)
    assert.is_truthy(notified[1].msg:find('no mermaid block', 1, true))
  end)

  it('says so when mmdc is missing', function()
    executables.mmdc = nil
    preview(doc, 4)
    assert.is_nil(command_of('mmdc'))
    assert.are.equal(vim.log.levels.ERROR, notified[1].level)
    assert.is_truthy(notified[1].msg:find('mmdc', 1, true))
  end)

  it('reports a failed render and shows nothing', function()
    results.mmdc = { code = 1, stderr = 'Parse error on line 2' }
    preview(doc, 4)
    assert.is_nil(command_of('kitten'))
    assert.are.equal(vim.log.levels.ERROR, notified[1].level)
    assert.is_truthy(notified[1].msg:find('Parse error', 1, true))
    assert.are.same({}, vim.fn.glob(cache_dir .. '/*', true, true))
  end)
end)
