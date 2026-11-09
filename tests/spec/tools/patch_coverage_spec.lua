local h = require('helpers')

describe('tools.patch_coverage', function()
  local pc, root, cleanup, notes, restores

  before_each(function()
    h.unload('tools.patch_coverage')
    pc = require('tools.patch_coverage')
    root, cleanup = h.tmpdir()
    notes = {}
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
    }
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function git(...)
    local result = vim
      .system({
        'git',
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        '-c',
        'commit.gpgsign=false',
        ...,
      }, { cwd = root })
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  local function noted(pattern)
    return vim.wait(5000, function()
      for _, note in ipairs(notes) do
        if note.msg:match(pattern) then return true end
      end
      return false
    end)
  end

  describe('reports', function()
    it('reads LCOV, relative to the root', function()
      h.write(root .. '/lcov.info', {
        'TN:',
        'SF:src/a.lua',
        'DA:1,3',
        'DA:2,0',
        'end_of_record',
        'SF:' .. root .. '/b.lua',
        'DA:5,1,abc',
        'end_of_record',
      })
      local data, format = pc.read(root .. '/lcov.info', root)
      assert.equals('LCOV', format)
      assert.same({ [1] = 3, [2] = 0 }, data[root .. '/src/a.lua'])
      assert.same({ [5] = 1 }, data[root .. '/b.lua'])
    end)

    it('reads Cobertura, against its sources', function()
      h.write(root .. '/src/pkg/m.py', { 'x = 1' })
      h.write(root .. '/coverage.xml', {
        '<?xml version="1.0" ?>',
        '<coverage version="7">',
        '  <sources><source>' .. root .. '/src</source></sources>',
        '  <packages><package name="pkg"><classes>',
        '    <class name="m.py" filename="pkg/m.py">',
        '      <lines>',
        '        <line number="1" hits="2"/>',
        '        <line number="3" hits="0" branch="true"/>',
        '      </lines>',
        '    </class>',
        '  </classes></package></packages>',
        '</coverage>',
      })
      local data, format = pc.read(root .. '/coverage.xml', root)
      assert.equals('Cobertura', format)
      assert.same({ [1] = 2, [3] = 0 }, data[root .. '/src/pkg/m.py'])
    end)

    it('reads a Go profile, the module standing for the root', function()
      h.write(root .. '/go.mod', { 'module example.com/m', '', 'go 1.22' })
      h.write(root .. '/coverage.out', {
        'mode: set',
        'example.com/m/pkg/a.go:3.10,5.2 2 1',
        'example.com/m/pkg/a.go:5.2,7.1 1 0',
      })
      local data, format = pc.read(root .. '/coverage.out', root)
      assert.equals('Go', format)
      -- line 5 is in both blocks: covered by the one that ran; line 7 is
      -- where the second ends, at column 1, so in neither
      assert.same(
        { [3] = 1, [4] = 1, [5] = 1, [6] = 0 },
        data[root .. '/pkg/a.go']
      )
    end)

    it('reads coverage.py JSON', function()
      h.write(root .. '/coverage.json', {
        vim.json.encode({
          meta = { version = '7' },
          files = {
            ['m.py'] = { executed_lines = { 1, 2 }, missing_lines = { 4 } },
          },
        }),
      })
      local data, format = pc.read(root .. '/coverage.json', root)
      assert.equals('coverage.py JSON', format)
      assert.same({ [1] = 1, [2] = 1, [4] = 0 }, data[root .. '/m.py'])
    end)

    it('says what a file it cannot read is', function()
      h.write(root .. '/coverage.json', { '{"totals": {}}' })
      local data, err = pc.read(root .. '/coverage.json', root)
      assert.is_nil(data)
      assert.matches('not LCOV', err)
    end)

    it('finds the newest report in the root and the coverage dirs', function()
      h.write(root .. '/coverage.out', { 'mode: set' })
      h.write(root .. '/coverage/lcov.info', { 'TN:' })
      h.write(root .. '/notes.txt', { 'x' })
      vim.uv.fs_utime(root .. '/coverage.out', 1000, 1000)
      local found = pc.reports(root)
      assert.equals(2, #found)
      assert.equals(root .. '/coverage/lcov.info', found[1].path)
    end)
  end)

  describe('parse_diff', function()
    it('gives the added and modified lines, not the deleted ones', function()
      local changed = pc.parse_diff(table.concat({
        'diff --git a/a.lua b/a.lua',
        '--- a/a.lua',
        '+++ b/a.lua',
        '@@ -1 +1 @@',
        '-x',
        '+y',
        '@@ -5,0 +6,3 @@',
        '+a',
        '@@ -9,2 +11,0 @@',
        'diff --git a/gone.lua b/gone.lua',
        '--- a/gone.lua',
        '+++ /dev/null',
        '@@ -1,2 +0,0 @@',
        'diff --git a/my file.lua b/my file.lua',
        '--- a/my file.lua\t',
        '+++ b/my file.lua\t',
        '@@ -0,0 +1,2 @@',
      }, '\n'))
      assert.same({
        ['a.lua'] = { [1] = true, [6] = true, [7] = true, [8] = true },
        ['my file.lua'] = { [1] = true, [2] = true },
      }, changed)
    end)
  end)

  describe('compute', function()
    it('counts only the changed lines the report calls executable', function()
      h.write(root .. '/a.lua', { '' })
      h.write(root .. '/new.lua', { '' })
      local now = os.time() + 60
      local data = {
        [root .. '/a.lua'] = { [1] = 1, [2] = 0, [3] = 0, [9] = 0 },
        [root .. '/new.lua'] = { [1] = 0, [2] = 4 },
      }
      local result = pc.compute(root, {
        -- line 4 is not executable, line 9 not changed
        ['a.lua'] = { [1] = true, [2] = true, [4] = true },
        ['new.lua'] = true,
        ['README.md'] = { [1] = true },
      }, data, now)
      assert.equals(2, result.covered)
      assert.equals(4, result.total)
      assert.equals('50.0%', pc.percent(result.covered, result.total))
      assert.is_false(result.stale)
      local by = {}
      for _, file in ipairs(result.files) do
        by[file.path] = file
      end
      assert.same({ 2 }, by['a.lua'].uncovered)
      assert.same({ 1 }, by['new.lua'].uncovered)
      assert.is_false(by['README.md'].known)
      local summary = table.concat(
        pc.summary(result, root .. '/lcov.info', 'LCOV', 'abcdef0123'),
        '\n'
      )
      assert.matches('50.0%%: 2 of 4', summary)
      assert.matches('Not in the report.-README.md', summary)
    end)

    it('flags a report older than a changed file it covers', function()
      h.write(root .. '/a.lua', { '' })
      local result = pc.compute(
        root,
        { ['a.lua'] = { [1] = true } },
        { [root .. '/a.lua'] = { [1] = 1 } },
        0
      )
      assert.is_true(result.stale)
      assert.is_true(result.files[1].stale)
      assert.matches(
        'STALE',
        table.concat(pc.summary(result, 'r', 'LCOV', 'abc'), '\n')
      )
    end)

    it(
      'gives no percentage when nothing counts',
      function() assert.equals('-', pc.percent(0, 0)) end
    )
  end)

  describe('run', function()
    before_each(function()
      table.insert(
        restores,
        h.stub(
          package.loaded,
          'util.root',
          setmetatable({}, {
            __call = function() return root end,
          })
        )
      )
    end)

    it('says how to make a report when there is none', function()
      pc.run()
      assert.is_true(noted('No coverage report'))
      assert.is_true(noted('<leader>tc'))
    end)

    it('marks the uncovered changed lines', function()
      git('init', '-q', '-b', 'main')
      h.write(root .. '/a.lua', { 'local a = 1', 'return a' })
      git('add', '.')
      git('commit', '-q', '-m', 'base')
      git('checkout', '-q', '-b', 'topic')
      h.write(root .. '/a.lua', { 'local a = 1', 'a = a + 1', 'return a + 0' })
      h.write(root .. '/lcov.info', {
        'SF:a.lua',
        'DA:1,1',
        'DA:2,0',
        'DA:3,1',
        'end_of_record',
      })
      pc.run()
      assert.is_true(noted('50.0%% of the changed lines'))
      local items = vim.fn.getqflist()
      assert.equals(1, #items)
      assert.equals(2, items[1].lnum)
      assert.equals(
        1,
        #vim.diagnostic.get(items[1].bufnr, { namespace = pc.NS })
      )
      pc.clear()
      assert.equals(
        0,
        #vim.diagnostic.get(items[1].bufnr, { namespace = pc.NS })
      )
      assert.equals(0, #vim.fn.getqflist())
    end)
  end)
end)
