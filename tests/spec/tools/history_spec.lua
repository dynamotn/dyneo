local h = require('helpers')

local SOURCE = {
  'local M = {}',
  '',
  'function M.add(a, b)',
  '  return a + b',
  'end',
  '',
  'function M.sub(a, b)',
  '  return a - b',
  'end',
  '',
  'return M',
}

describe('tools.history', function()
  local history, dir, cleanup, notes, restore_notify

  before_each(function()
    h.unload('tools.history')
    history = require('tools.history')
    dir, cleanup = h.tmpdir()
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    restore_notify()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function git(args)
    local result = require('util.system').sync(
      vim.list_extend({
        'git',
        '-c',
        'user.name=Tester',
        '-c',
        'user.email=t@example.com',
        '-c',
        'commit.gpgsign=false',
      }, args),
      { cwd = dir, timeout = 10000 }
    )
    assert.equals(0, result.code, result.stderr)
  end

  --- A node of `kind` from row `first` to `last` (0-based), in `parent`
  local function node(kind, first, last, parent)
    return {
      type = function() return kind end,
      parent = function() return parent end,
      range = function() return first, 0, last, 3 end,
    }
  end

  it('reads the innermost definition around a node', function()
    local chunk = node('chunk', 0, 10)
    local fn = node('function_declaration', 2, 4, chunk)
    local body = node('block', 3, 3, fn)
    local ret = node('return_statement', 3, 3, body)
    assert.same({ 3, 5, 'function_declaration' }, { history.enclosing(ret) })
    -- A Terraform block at the top of the file is one
    local tf =
      node('block', 0, 6, node('body', 0, 9, node('config_file', 0, 9)))
    assert.same(
      { 1, 7, 'block' },
      { history.enclosing(node('attribute', 1, 1, tf)) }
    )
    -- A call, an argument or a parameter list is none
    local call = node('function_call', 5, 5, chunk)
    assert.is_nil(history.enclosing(node('arguments', 5, 5, call)))
    assert.is_nil(history.enclosing(nil))
    -- A method call in a function is the function's, not a definition
    local echo = node('method_index_expression', 3, 3, body)
    assert.same({ 3, 5, 'function_declaration' }, { history.enclosing(echo) })
    -- The root of a Python file, a C enumerator, a Java call are none
    assert.is_nil(history.enclosing(node('module', 0, 99)))
    assert.is_nil(history.enclosing(node('enumerator', 4, 4, chunk)))
    assert.is_nil(history.enclosing(node('method_invocation', 4, 4, chunk)))
    -- Rust, Go and JavaScript name theirs so
    for _, kind in ipairs({
      'impl_item',
      'type_spec',
      'method_definition',
      'arrow_function',
      'local_function_declaration',
    }) do
      assert.equals(kind, select(3, history.enclosing(node(kind, 1, 2, chunk))))
    end
  end)

  it('finds the definition the cursor is in, with the Lua parser', function()
    if not pcall(vim.treesitter.language.add, 'lua') then
      return pending('no Lua parser on this machine')
    end
    if not vim.treesitter.language.add('lua') then
      return pending('no Lua parser on this machine')
    end
    local bufnr = h.buffer({ lines = SOURCE, filetype = 'lua' })
    assert.same({ 3, 5 }, { history.definition_at(bufnr, 4) })
    assert.same({ 7, 9 }, { history.definition_at(bufnr, 7) })
    assert.is_nil(history.definition_at(bufnr, 11))
  end)

  it('finds no definition without a parser', function()
    local bufnr = h.buffer({ lines = { 'x' }, filetype = 'nosuchlanguage' })
    assert.is_nil(history.definition_at(bufnr, 1))
  end)

  it(
    'asks git for the lines of the file, by their path in the repository',
    function()
      assert.same({
        'git',
        '-C',
        '/r',
        'log',
        '--no-color',
        '--date=short',
        '--format=commit %h  %ad  %an%n%n    %s%n',
        '--max-count=30',
        '-L3,5:lua/x.lua',
      }, history.log_command('/r', 'lua/x.lua', 3, 5))
    end
  )

  it('finds a file through a link into the repository', function()
    git({ 'init', '-q' })
    h.write(dir .. '/repo/x.lua', SOURCE)
    vim.fn.mkdir(dir .. '/elsewhere', 'p')
    vim.uv.fs_symlink(dir .. '/repo/x.lua', dir .. '/elsewhere/x.lua')
    assert.same(
      { dir, 'repo/x.lua' },
      { history.locate(dir .. '/elsewhere/x.lua') }
    )
    assert.is_nil(history.locate('/nonexistent/x.lua'))
  end)

  it('reads lines of the file on disk as lines of HEAD', function()
    local diff = table.concat({
      'diff --git a/m.lua b/m.lua',
      '--- a/m.lua',
      '+++ b/m.lua',
      -- Three lines added at the top
      '@@ -0,0 +1,3 @@',
      '+-- a',
      '+-- b',
      '+-- c',
      -- Line 8 of HEAD changed
      '@@ -8 +11 @@',
      '-old',
      '+new',
      -- Lines 10-11 of HEAD removed
      '@@ -10,2 +12,0 @@',
      '-x',
      '-y',
    }, '\n')
    assert.same({ 3, 5 }, { history.map_range(diff, 6, 8) })
    -- The changed line was line 8; what follows the removal moves up
    assert.same({ 8, 8 }, { history.map_range(diff, 11, 11) })
    assert.same({ 9, 9 }, { history.map_range(diff, 12, 12) })
    assert.same({ 12, 12 }, { history.map_range(diff, 13, 13) })
    -- Lines added since HEAD have none
    assert.is_nil(history.map_range(diff, 1, 3))
    assert.same({ 1, 1 }, { history.map_range('', 1, 1) })
  end)

  it('follows the function past uncommitted lines above it', function()
    git({ 'init', '-q' })
    h.write(dir .. '/m.lua', SOURCE)
    git({ 'add', 'm.lua' })
    git({ 'commit', '-q', '-m', 'add both' })
    h.write(
      dir .. '/m.lua',
      vim.list_extend({ '-- a', '-- b', '-- c' }, SOURCE)
    )
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/m.lua'))
    local done = false
    history.show(6, 8, 'function', function() done = true end)
    assert.is_true(vim.wait(10000, function() return done end, 10))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert.is_truthy(text:find('Lines 3-5 at HEAD', 1, true))
    assert.is_truthy(text:find('function M.add', 1, true))
    assert.is_falsy(text:find('function M.sub', 1, true))
  end)

  it('says a file git does not track has no history', function()
    git({ 'init', '-q' })
    h.write(dir .. '/new.lua', SOURCE)
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/new.lua'))
    local done = false
    history.show(3, 5, 'function', function() done = true end)
    assert.is_true(vim.wait(10000, function() return done end, 10))
    assert.equals(
      'new.lua is not committed yet: it has no history',
      notes[#notes]
    )
  end)

  it('shows the commits that changed the function, and no other', function()
    git({ 'init', '-q' })
    h.write(dir .. '/m.lua', SOURCE)
    git({ 'add', 'm.lua' })
    git({ 'commit', '-q', '-m', 'add both' })
    local changed = vim.deepcopy(SOURCE)
    changed[8] = '  return a - b - 0'
    h.write(dir .. '/m.lua', changed)
    git({ 'commit', '-q', '-am', 'touch sub only' })
    changed[4] = '  return b + a'
    h.write(dir .. '/m.lua', changed)
    git({ 'commit', '-q', '-am', 'touch add only' })

    vim.cmd.edit(vim.fn.fnameescape(dir .. '/m.lua'))
    vim.api.nvim_win_set_cursor(0, { 4, 0 })
    local done = false
    history.show(3, 5, 'function', function() done = true end)
    assert.is_true(vim.wait(10000, function() return done end, 10))
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert.is_truthy(text:find('# function, lines 3-5 of m.lua', 1, true))
    assert.is_truthy(text:find('touch add only', 1, true))
    assert.is_truthy(text:find('add both', 1, true))
    assert.is_falsy(text:find('touch sub only', 1, true))
    assert.equals('git', vim.bo.filetype)
  end)

  it(
    'says when the file is not in a repository, or no definition is found',
    function()
      h.write(dir .. '/m.lua', SOURCE)
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/m.lua'))
      history.show(1, 2, 'Selection')
      vim.api.nvim_win_set_cursor(0, { 11, 0 })
      history.command({ range = 0, line1 = 11, line2 = 11 })
      assert.same({
        'Not a file of a git repository',
        'No definition under the cursor that tree-sitter knows: select the lines',
      }, notes)
    end
  )
end)
