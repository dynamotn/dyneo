local h = require('helpers')

-- A jest `--json` failure message as jest 29 writes it
local JEST_MESSAGE = table.concat({
  'Error: expect(received).toMatchSnapshot()',
  '',
  'Snapshot name: `obj 1`',
  '',
  '- Snapshot  - 1',
  '+ Received  + 1',
  '',
  '  {',
  '-   "a": 1,',
  '+   "a": 3,',
  '  }',
  '    at Object.<anonymous> (/p/j/b.test.cjs:1:148)',
}, '\n')

-- A pytest JUnit report (`xunit1`) of two failing syrupy snapshots
local JUNIT = table.concat({
  '<?xml version="1.0" encoding="utf-8"?><testsuites><testsuite>',
  '<testcase classname="tests.test_a" name="test_ok" file="tests/test_a.py" line="9" time="0"/>',
  '<testcase classname="tests.test_a" name="test_dict" file="tests/test_a.py" line="0" time="0.001">'
    .. "<failure message=\"AssertionError: assert [+ received] == [- snapshot]&#10;    dict({&#10;  -   'a': 1,&#10;  +   'a': 2,&#10;    })\">"
    .. 'snapshot = dict({&#10;</failure></testcase>',
  '<testcase classname="tests.test_a.TestC" name="test_s" file="tests/test_a.py" line="3" time="0.001">'
    .. "<failure message=\"AssertionError: assert [+ received] == [- snapshot]&#10;  - 'hello'&#10;  + 'hullo'\">x</failure></testcase>",
  '<testcase classname="tests.test_a" name="test_other" file="tests/test_a.py" line="7" time="0">'
    .. '<failure message="assert 1 == 2">x</failure></testcase>',
  '</testsuite></testsuites>',
}, '\n')

describe('tools.snapshots', function()
  local snapshots, dir, root, cleanup, path, notes, restores, answer, picked

  before_each(function()
    h.unload('tools.snapshots')
    snapshots = require('tools.snapshots')
    dir, cleanup = h.tmpdir()
    dir = vim.uv.fs_realpath(dir)
    root = dir .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root, 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, answer, picked = {}, 1, nil
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(
        package.loaded,
        'util.trust',
        { ask = function() return true end }
      ),
      h.stub(package.loaded, 'util.root', { get = function() return root end }),
      h.stub(vim.fn, 'confirm', function() return answer end),
      h.stub(_G, 'Snacks', {
        picker = { pick = function(opts) picked = opts end },
      }),
    }
  end)
  after_each(function()
    snapshots.quit()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! tabonly')
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function fake(file, body)
    h.write(file, { '#!/bin/sh', unpack(vim.split(body, '\n')) })
    vim.fn.setfperm(file, 'rwxr-xr-x')
  end

  local function noted(pattern)
    return vim.wait(5000, function()
      for _, note in ipairs(notes) do
        if note.msg:match(pattern) then return true end
      end
      return false
    end)
  end

  --- The items `scan` finds under `root`
  local function scan()
    local items, runner
    snapshots.scan(root, function(i, r)
      items, runner = i or false, r
    end)
    assert.is_true(vim.wait(10000, function() return items ~= nil end))
    return items, runner
  end

  --- An insta pair under `src/snapshots/` of the project
  local function insta(old, new)
    local base = root .. '/src/snapshots/crate__tests__greets.snap'
    vim.fn.mkdir(root .. '/src/snapshots', 'p')
    if old then
      h.write(base, { '---', 'source: src/lib.rs', '---', unpack(old) })
    end
    h.write(base .. '.new', {
      '---',
      'source: src/lib.rs',
      'assertion_line: 5',
      '---',
      unpack(new),
    })
    return base
  end

  describe('split', function()
    it('parts the header from the body', function()
      local header, body = snapshots.split({ '---', 'source: x', '---', 'a' })
      assert.same({ '---', 'source: x', '---' }, header)
      assert.same({ 'a' }, body)
      header, body = snapshots.split({ 'plain' })
      assert.same({}, header)
      assert.same({ 'plain' }, body)
    end)
  end)

  describe('diff sides', function()
    it('reads both sides of a jest message', function()
      local old, new = snapshots.jest_sides(JEST_MESSAGE)
      assert.same({ '{', '  "a": 1,', '}' }, old)
      assert.same({ '{', '  "a": 3,', '}' }, new)
    end)

    it(
      'says nothing of a message with no diff',
      function()
        assert.is_nil(snapshots.jest_sides('Error: Snapshot `x 1` mismatched'))
      end
    )
  end)

  describe('insta', function()
    it('finds .snap.new files, skipping target/', function()
      insta({ 'hello' }, { 'hi' })
      vim.fn.mkdir(root .. '/target/x', 'p')
      h.write(root .. '/target/x/a.snap.new', { 'x' })
      h.write(root .. '/src/.lib.rs.pending-snap', { '{}' })
      local items = scan()
      assert.equals(1, #items)
      assert.equals('crate::tests::greets', items[1].name)
      local old, new = snapshots.sides(items[1])
      assert.same({ 'hello' }, old)
      assert.same({ 'hi' }, new)
      assert.is_true(noted('1 files of inline insta snapshots'))
    end)

    it('shows a new snapshot against nothing', function()
      insta(nil, { 'hi' })
      local items = scan()
      assert.is_nil(items[1].target)
      assert.same({}, (snapshots.sides(items[1])))
    end)

    it('accepts by moving the new file over the old', function()
      local base = insta({ 'hello' }, { 'hi' })
      local items = scan()
      local ok
      snapshots.accept(items[1], nil, function(r) ok = r end)
      assert.is_true(ok)
      assert.is_nil(vim.uv.fs_stat(base .. '.new'))
      assert.same('assertion_line: 5', vim.fn.readfile(base)[3])
    end)

    it('rejects by deleting the new file, once confirmed', function()
      local base = insta({ 'hello' }, { 'hi' })
      local items = scan()
      answer = 2
      assert.is_false(snapshots.reject(items[1]))
      assert.is_not_nil(vim.uv.fs_stat(base .. '.new'))
      answer = 1
      assert.is_true(snapshots.reject(items[1]))
      assert.is_nil(vim.uv.fs_stat(base .. '.new'))
      assert.same({ 'hello' }, vim.list_slice(vim.fn.readfile(base), 4))
    end)

    it('rejects all, once confirmed with the count', function()
      local base = insta({ 'hello' }, { 'hi' })
      local items = scan()
      local asked
      restores[#restores + 1] = h.stub(vim.fn, 'confirm', function(q)
        asked = q
        return 1
      end)
      snapshots.all(items, nil, 'reject-all')
      assert.matches('Delete all 1 pending', asked)
      assert.is_nil(vim.uv.fs_stat(base .. '.new'))
    end)
  end)

  describe('jest and vitest', function()
    it('lists the failing snapshots of a jest report', function()
      local report = vim.json.encode({
        testResults = {
          {
            name = root .. '/j/b.test.cjs',
            assertionResults = {
              { failureMessages = { JEST_MESSAGE } },
              { failureMessages = { 'Error: expected 1 to be 2' } },
            },
          },
        },
      })
      local items = snapshots.js_items(root, 'jest', 'noise\n' .. report)
      assert.equals(1, #items)
      assert.equals('obj 1', items[1].name)
      assert.same({ '{', '  "a": 3,', '}' }, items[1].new)
    end)

    it('reads the stored side of a vitest snapshot', function()
      h.write(root .. '/v/__snapshots__/a.test.js.snap', {
        '// Vitest Snapshot v1',
        '',
        'exports[`obj 1`] = `',
        '{',
        '  "a": 1,',
        '}',
        '`;',
      })
      local report = vim.json.encode({
        testResults = {
          {
            name = root .. '/v/a.test.js',
            assertionResults = {
              {
                failureMessages = {
                  'Error: Snapshot `obj 1` mismatched\n    at x (y:1:2)',
                },
              },
            },
          },
        },
      })
      local items = snapshots.js_items(root, 'vitest', report)
      assert.same({ '{', '  "a": 1,', '}' }, items[1].old)
    end)

    it('says when the report counts snapshots it does not name', function()
      local report = vim.json.encode({
        snapshot = { unmatched = 2 },
        testResults = {
          {
            name = root .. '/j/b.test.cjs',
            assertionResults = {
              { failureMessages = { JEST_MESSAGE } },
              { failureMessages = { '@/j/b.test.cjs:5:21' } },
            },
          },
        },
      })
      local items, err = snapshots.js_items(root, 'jest', report)
      assert.equals(1, #items)
      assert.equals('1 of 2 failing snapshots have no name in the report', err)
    end)

    it('fails loudly on a report that is no JSON', function()
      local items, err = snapshots.js_items(root, 'jest', 'boom')
      assert.is_nil(items)
      assert.matches('no JSON', err)
    end)

    it('scans with jest, then accepts per file with -u', function()
      h.write(root .. '/package.json', { '{}' })
      local report = vim.json.encode({
        testResults = {
          {
            name = root .. '/j/b.test.cjs',
            assertionResults = { { failureMessages = { JEST_MESSAGE } } },
          },
        },
      })
      h.write(dir .. '/report.json', { report })
      fake(
        root .. '/node_modules/.bin/jest',
        ('echo "$@" >> %s/calls\ncase "$*" in *-u*) exit 0;; esac\ncat %s/report.json\nexit 1'):format(
          dir,
          dir
        )
      )
      local items, runner = scan()
      assert.equals('jest', runner.kind)
      assert.equals(1, #items)
      local ok
      snapshots.accept(items[1], runner, function(r) ok = r end)
      assert.is_true(vim.wait(5000, function() return ok ~= nil end))
      assert.is_true(ok)
      local calls = vim.fn.readfile(dir .. '/calls')
      assert.equals('--ci --json', calls[1])
      assert.equals(
        '--ci=false -u --runTestsByPath ' .. root .. '/j/b.test.cjs',
        calls[2]
      )
    end)

    it('builds the vitest commands', function()
      local runner = { kind = 'vitest', bin = 'vitest' }
      assert.same(
        { 'vitest', 'run', '--reporter=json' },
        snapshots.scan_command(runner, 'r')
      )
      assert.same(
        { 'vitest', 'run', '-u', 'a.test.js' },
        snapshots.accept_command(runner, 'a.test.js')
      )
    end)
  end)

  describe('syrupy', function()
    it('lists the failing snapshots of a JUnit report', function()
      local items = snapshots.syrupy_items(root, JUNIT)
      assert.equals(2, #items)
      assert.equals('test_dict', items[1].name)
      assert.equals(root .. '/tests/test_a.py', items[1].file)
      assert.same({ 'dict({', "  'a': 1,", '})' }, items[1].old)
      assert.same({ 'dict({', "  'a': 2,", '})' }, items[1].new)
      assert.equals('TestC::test_s', items[2].name)
      assert.same({ "'hello'" }, items[2].old)
    end)

    it('scans with the project pytest and accepts per file', function()
      vim.fn.mkdir(root .. '/tests/__snapshots__', 'p')
      h.write(root .. '/tests/__snapshots__/test_a.ambr', { '# serializer' })
      h.write(dir .. '/junit.xml', vim.split(JUNIT, '\n'))
      fake(
        root .. '/.venv/bin/pytest',
        table.concat({
          ('echo "$@" >> %s/calls'):format(dir),
          'while [ $# -gt 0 ]; do',
          ('  [ "$1" = --junitxml ] && cp %s/junit.xml "$2"'):format(dir),
          '  shift',
          'done',
          'exit 1',
        }, '\n')
      )
      local items, runner = scan()
      assert.equals('syrupy', runner.kind)
      assert.equals(2, #items)
      assert.same({
        runner.bin,
        '-q',
        '-p',
        'no:cacheprovider',
        '--snapshot-update',
        'f.py',
      }, snapshots.accept_command(runner, 'f.py'))
    end)

    it('says a run that wrote no report, not a clean result', function()
      vim.fn.mkdir(root .. '/tests/__snapshots__', 'p')
      h.write(root .. '/tests/__snapshots__/test_a.ambr', { '# serializer' })
      fake(root .. '/.venv/bin/pytest', 'echo broken >&2\nexit 4')
      local items = scan()
      assert.same({}, items)
      assert.is_true(noted('syrupy snapshots: pytest wrote no report'))
    end)
  end)

  describe('open', function()
    it('says when nothing is pending', function()
      snapshots.open()
      assert.is_true(noted('^No pending snapshots$'))
      assert.is_nil(picked)
    end)

    it('picks, then reviews in a diff tab with its keys', function()
      local base = insta({ 'hello' }, { 'hi' })
      snapshots.open()
      assert.is_true(vim.wait(5000, function() return picked ~= nil end))
      local item = picked.items[1]
      assert.matches('src/snapshots/crate__tests__greets.snap.new', item.text)
      assert.matches('%-hello\n%+hi', item.preview.text)
      picked.confirm({ close = function() end }, item)
      local wins = vim.api.nvim_tabpage_list_wins(0)
      assert.equals(2, #wins)
      assert.is_true(vim.wo[wins[1]].diff and vim.wo[wins[2]].diff)
      assert.same(
        { 'hello' },
        vim.api.nvim_buf_get_lines(
          vim.api.nvim_win_get_buf(wins[1]),
          0,
          -1,
          false
        )
      )
      vim.api.nvim_feedkeys('a', 'x', false)
      assert.is_nil(vim.uv.fs_stat(base .. '.new'))
      assert.is_nil(snapshots.session)
      assert.is_true(noted('No more pending snapshots'))
    end)
  end)
end)
