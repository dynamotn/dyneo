local h = require('helpers')

-- The buffer-local mappings `ftplugin/` gives a filetype: each loads its
-- tool on the key, not with the buffer, so the tool is stood in for here and
-- the mapping shown to call the right function of it
describe('ftplugin mappings', function()
  local restores
  before_each(function() restores = {} end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  --- A fake module recording the calls to the functions named
  ---@param module string
  ---@param names string[]
  ---@return table<string, any[][]> calls By function name
  local function fake(module, names)
    local calls, stub = {}, {}
    for _, name in ipairs(names) do
      calls[name] = {}
      stub[name] = function(...) table.insert(calls[name], { ... }) end
    end
    table.insert(restores, h.stub(package.loaded, module, stub))
    return calls
  end

  ---@param ft string
  local function open(ft)
    local bufnr = h.buffer()
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].filetype = ft
    return bufnr
  end

  --- The buffer-local normal mapping of `lhs`, which must exist
  ---@param lhs string
  ---@return table
  local function mapping(lhs)
    local map = vim.fn.maparg(lhs, 'n', false, true)
    assert.are.equal(1, map.buffer, lhs)
    return map
  end

  it('runs markdown blocks with the runbook', function()
    local names = {
      'run',
      'run_all',
      'run_from',
      'record',
      'clear',
      'stop',
      'forget_inputs',
    }
    local calls = fake('tools.runbook', names)
    open('markdown')
    for lhs, name in pairs({
      ['<localleader>r'] = 'run',
      ['<localleader>R'] = 'run_all',
      ['<localleader>F'] = 'run_from',
      ['<localleader>L'] = 'record',
      ['<localleader>x'] = 'clear',
      ['<localleader>s'] = 'stop',
      ['<localleader>I'] = 'forget_inputs',
    }) do
      local map = mapping(lhs)
      assert.truthy(map.desc:find('Runbook', 1, true), lhs)
      map.callback()
      assert.are.equal(1, #calls[name], name)
    end
  end)

  it('opens the decision matrix from markdown', function()
    open('markdown')
    assert.are.equal('<cmd>DyMatrix<cr>', mapping('<localleader>m').rhs)
  end)

  it('writes the commit message with AI', function()
    local calls = fake('tools.ai.commit', { 'write' })
    open('gitcommit')
    mapping('<localleader>g').callback()
    assert.are.equal(1, #calls.write)
  end)

  it('previews a D2 diagram of the buffer', function()
    local calls = fake('tools.diagram.d2.snacks', { 'preview' })
    open('d2')
    mapping('<leader>cp').callback()
    assert.same({ { 0 } }, calls.preview)
  end)

  it('moves between Python cells, and selects one', function()
    local calls = fake('util.cells', { 'jump', 'textobject' })
    local bufnr = open('python')
    for _, mode in ipairs({ 'n', 'x', 'o' }) do
      assert.are.equal(1, vim.fn.maparg(']j', mode, false, true).buffer, mode)
    end
    mapping(']j').callback()
    mapping('[j').callback()
    assert.same({ {}, { true } }, calls.jump)
    assert.are.equal(
      package.loaded['util.cells'].textobject,
      vim.b[bufnr].miniai_config.custom_textobjects.j
    )
  end)
end)
