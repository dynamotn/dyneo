local h = require('helpers')

describe('tools.testaffected', function()
  local ta, dir, root, cleanup, path, notes, restores, ran, jobs

  before_each(function()
    h.unload('tools.testaffected')
    ta = require('tools.testaffected')
    dir, cleanup = h.tmpdir()
    root = dir .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root, 'p')
    path = vim.env.PATH
    -- The fakes of this spec and git, whatever else the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, ran, jobs = {}, {}, {}
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(package.loaded, 'neotest', {
        run = { run = function(p) table.insert(ran, p) end },
      }),
      h.stub(vim.fn, 'jobstart', function(cmd, opts)
        table.insert(jobs, { cmd = cmd, opts = opts })
        return 1
      end),
      h.stub(ta, 'has_adapter', function() return true end),
    }
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! stopinsert')
    vim.cmd('silent! only')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function noted(pattern, level)
    return vim.wait(5000, function()
      for _, note in ipairs(notes) do
        if
          note.msg:match(pattern) and (level == nil or note.level == level)
        then
          return true
        end
      end
      return false
    end)
  end

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
    return vim.trim(result.stdout)
  end

  --- A fake `name` printing `out` and exiting `code`
  local function fake(name, out, code)
    h.write(dir .. '/' .. name .. '.out', vim.split(out, '\n'))
    h.write(dir .. '/bin/' .. name, {
      '#!/bin/sh',
      'cat "' .. dir .. '/' .. name .. '.out"',
      'exit ' .. (code or 0),
    })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  --- `M.changed` waited for
  local function changed(ref)
    local got
    ta.changed(
      root,
      ref,
      function(files, err, base) got = { files = files, err = err, base = base } end
    )
    assert.is_true(vim.wait(5000, function() return got ~= nil end))
    return got
  end

  describe('changed', function()
    it('takes committed, uncommitted and untracked files', function()
      git('init', '-q', '-b', 'main')
      h.write(root .. '/a.txt', { 'a' })
      h.write(root .. '/old.txt', { 'o' })
      git('add', '-A')
      git('commit', '-q', '-m', 'one')
      local base = git('rev-parse', 'HEAD')
      git('checkout', '-q', '-b', 'feat')
      h.write(root .. '/sub/b.txt', { 'b' })
      git('add', '-A')
      git('commit', '-q', '-m', 'two')
      h.write(root .. '/a.txt', { 'changed' })
      h.write(root .. '/c.txt', { 'new' })

      local got = changed()
      assert.is_nil(got.err)
      assert.equals(base, got.base)
      assert.same({ 'a.txt', 'c.txt', 'sub/b.txt' }, got.files)

      -- Against the branch's own commit only what is not committed is left
      got = changed('HEAD')
      assert.same({ 'a.txt', 'c.txt' }, got.files)
    end)

    it('says why outside a repository or with a bad ref', function()
      local got = changed()
      assert.is_nil(got.files)
      assert.matches('No default branch', got.err)

      got = changed('--output=x')
      assert.is_nil(got.files)
      assert.matches('Not a ref', got.err)
    end)
  end)

  describe('python', function()
    it('reads absolute and relative imports', function()
      assert.same(
        { 'pkg.a', 'pkg.b', 'os' },
        vim.list_extend(
          ta.python_imports('t.py', 'import pkg.a, pkg.b as b'),
          ta.python_imports('t.py', 'import os  # comment')
        )
      )
      assert.same(
        { 'pkg.mod', 'pkg.mod.x', 'pkg.mod.y' },
        ta.python_imports('t.py', 'from pkg.mod import (x, y as z)')
      )
      assert.same(
        { 'pkg.sub.helpers', 'pkg.sub.helpers.f' },
        ta.python_imports('src/pkg/sub/m.py', 'from .helpers import f')
      )
      assert.same(
        { 'pkg', 'pkg.util' },
        ta.python_imports('src/pkg/sub/__init__.py', 'from .. import util')
      )
      assert.same({}, ta.python_imports('t.py', 'x = 1'))
      -- The names are on lines `git grep` leaves out
      assert.same(
        { 'app.services', 'app.services.*' },
        ta.python_imports('t.py', 'from app.services import (')
      )
      assert.same(
        { 'app.services', 'app.services.*', 'app.services.a' },
        ta.python_imports('t.py', 'from app.services import a, \\')
      )
    end)

    it('reaches a module named only on a wrapped import line', function()
      for _, file in ipairs({ 'app/services/billing.py', 'tests/test_bill.py' }) do
        h.write(root .. '/' .. file)
      end
      local grep = 'tests/test_bill.py\0from app.services import ('
      assert.same({
        {
          path = 'tests/test_bill.py',
          why = 'imports app/services/billing.py',
        },
      }, ta.python_targets(root, grep, { 'app/services/billing.py' }))
    end)

    it('follows imports transitively to the tests', function()
      for _, file in ipairs({
        'src/pkg/core.py',
        'src/pkg/api.py',
        'src/pkg/other.py',
        'tests/test_api.py',
        'tests/test_other.py',
        'tests/conftest.py',
      }) do
        h.write(root .. '/' .. file)
      end
      local grep = table.concat({
        'src/pkg/api.py\0from .core import thing',
        'tests/test_api.py\0from pkg import api',
        'tests/test_other.py\0import pkg.other',
      }, '\n')
      assert.same({
        { path = 'tests/test_api.py', why = 'imports src/pkg/core.py' },
      }, ta.python_targets(root, grep, { 'src/pkg/core.py' }))
      -- A changed test is affected; a changed fixture file takes its dir
      assert.same(
        {
          { path = 'tests/test_other.py', why = 'changed' },
          { path = 'tests', why = 'changed tests/conftest.py' },
        },
        ta.python_targets(root, grep, {
          'tests/conftest.py',
          'tests/test_other.py',
        })
      )
    end)
  end)

  describe('javascript', function()
    it('follows relative imports to the tests', function()
      for _, file in ipairs({
        'src/add.ts',
        'src/lib/index.ts',
        'src/twice.ts',
        'test/twice.test.ts',
        'test/lib.spec.js',
        'test/other.test.ts',
      }) do
        h.write(root .. '/' .. file)
      end
      local grep = table.concat({
        "src/twice.ts\0import { add } from './add.js'",
        "test/twice.test.ts\0import { twice } from '../src/twice'",
        "test/lib.spec.js\0const lib = require('../src/lib')",
        "src/lib/index.ts\0export * from '../add'",
      }, '\n')
      assert.same({
        { path = 'test/lib.spec.js', why = 'imports src/add.ts' },
        { path = 'test/twice.test.ts', why = 'imports src/add.ts' },
      }, ta.js_targets(root, grep, { 'src/add.ts' }))
    end)
  end)

  describe('go', function()
    local function line(dir_, path_, imports, test_imports, tests)
      return table.concat({ dir_, path_, imports, test_imports, tests }, '\t')
    end

    it('takes the packages importing a changed one', function()
      local out = table.concat({
        line(root, 'ex', '', '', 't'),
        line(root .. '/core', 'ex/core', 'fmt', '', 't'),
        line(root .. '/api', 'ex/api', 'ex/core', '', ''),
        line(root .. '/cmd', 'ex/cmd', 'ex/api', '', 't'),
        line(root .. '/e2e', 'ex/e2e', '', 'ex/core ', 't'),
      }, '\n')
      assert.same({
        { path = 'cmd', why = 'imports ex/api' },
        { path = 'core', why = 'changed' },
        { path = 'e2e', why = 'its tests import ex/core' },
      }, ta.go_targets(root, out, { 'core/core.go' }))
      assert.same(
        { { path = '.', why = 'changed' } },
        ta.go_targets(root, out, { 'main.go' })
      )
    end)
  end)

  describe('rust', function()
    it('takes the crates depending on a changed one', function()
      local metadata = {
        packages = {
          {
            name = 'core',
            manifest_path = root .. '/crates/core/Cargo.toml',
            dependencies = { { name = 'serde' } },
          },
          {
            name = 'api',
            manifest_path = root .. '/crates/api/Cargo.toml',
            dependencies = { { name = 'core', path = root .. '/crates/core' } },
          },
          {
            name = 'app',
            manifest_path = root .. '/Cargo.toml',
            dependencies = { { name = 'api' } },
          },
          {
            name = 'lone',
            manifest_path = root .. '/crates/lone/Cargo.toml',
            dependencies = {},
          },
        },
      }
      local targets, names =
        ta.rust_targets(root, metadata, { 'crates/core/src/lib.rs' })
      assert.same({
        { path = '.', why = 'depends on api' },
        { path = 'crates/api', why = 'depends on core' },
        { path = 'crates/core', why = 'changed' },
      }, targets)
      assert.same({ 'app', 'api', 'core' }, names)
      targets = ta.rust_targets(root, metadata, { 'src/main.rs' })
      assert.same({ { path = '.', why = 'changed' } }, targets)
    end)
  end)

  describe('run_files', function()
    it('says when nothing changed', function()
      ta.run_files(root, {}, 'abcdef0123')
      assert.is_true(noted('Nothing changed since abcdef01'))
    end)

    it('says when no change is of a language it maps', function()
      h.write(root .. '/go.mod', { 'module ex' })
      ta.run_files(root, { 'README.md' }, 'abcdef0123')
      assert.is_true(noted('No test is affected', vim.log.levels.WARN))
    end)

    it('hands the affected packages to neotest and says why', function()
      h.write(root .. '/go.mod', { 'module ex' })
      fake(
        'go',
        table.concat({
          root .. '/core\tex/core\t\t\tt',
          root .. '/cmd\tex/cmd\tex/core\t\tt',
        }, '\n')
      )
      ta.run_files(root, { 'core/x.go' }, 'abcdef0123')
      assert.is_true(noted('cmd %(imports ex/core%)'))
      assert.same({ root .. '/cmd', root .. '/core' }, ran)
    end)

    it('places packages go names through a symlink', function()
      h.write(root .. '/go.mod', { 'module ex' })
      vim.fn.mkdir(root .. '/core', 'p')
      assert.is_true(vim.uv.fs_symlink(root, dir .. '/link'))
      -- go names directories from $PWD, which may be a symlink
      fake('go', dir .. '/link/core\tex/core\t\t\tt')
      ta.run_files(root, { 'core/x.go' }, 'abcdef0123')
      assert.is_true(noted('core %(changed%)'))
      assert.same({ root .. '/core' }, ran)
    end)

    it('says nothing is affected when no test is', function()
      h.write(root .. '/go.mod', { 'module ex' })
      fake('go', root .. '/core\tex/core\t\t\t')
      ta.run_files(root, { 'core/x.go' }, 'abcdef0123')
      assert.is_true(noted('No test is affected by the 1 changed files'))
      assert.same({}, ran)
    end)

    it('says a mapping failed, never that nothing is affected', function()
      h.write(root .. '/go.mod', { 'module ex' })
      fake('go', 'go: broken', 1)
      ta.run_files(root, { 'core/x.go' }, 'abcdef0123')
      assert.is_true(noted('Go: tests not mapped', vim.log.levels.ERROR))
      for _, note in ipairs(notes) do
        assert.not_matches('No test is affected', note.msg)
      end
    end)

    it('says a missing tool is missing', function()
      h.write(root .. '/go.mod', { 'module ex' })
      -- `go` may sit in `/usr/bin`, which this spec keeps for git
      local executable = vim.fn.executable
      table.insert(
        restores,
        h.stub(
          vim.fn,
          'executable',
          function(name)
            return vim.fs.basename(name) == 'go' and 0 or executable(name)
          end
        )
      )
      ta.run_files(root, { 'core/x.go' }, 'abcdef0123')
      assert.is_true(noted('go is not installed', vim.log.levels.ERROR))
    end)

    it('asks jest for the related tests', function()
      h.write(root .. '/package.json', { '{}' })
      h.write(root .. '/src/a.js')
      h.write(root .. '/test/a.test.js')
      h.write(dir .. '/jest.out', { root .. '/test/a.test.js' })
      h.write(root .. '/node_modules/.bin/jest', {
        '#!/bin/sh',
        'echo "$@" > "' .. dir .. '/jest.args"',
        'cat "' .. dir .. '/jest.out"',
      })
      vim.fn.setfperm(root .. '/node_modules/.bin/jest', 'rwxr-xr-x')
      ta.run_files(root, { 'gone.js', 'src/a.js' }, 'abcdef0123')
      assert.is_true(noted('test/a.test.js %(jest: related%)'))
      assert.same(
        { '--listTests --findRelatedTests src/a.js' },
        vim.fn.readfile(dir .. '/jest.args')
      )
      assert.same({ root .. '/test/a.test.js' }, ran)
    end)

    it('runs in a terminal without a neotest adapter', function()
      restores[#restores + 1] = h.stub(
        ta,
        'has_adapter',
        function() return false end
      )
      h.write(root .. '/go.mod', { 'module ex' })
      fake('go', root .. '/core\tex/core\t\t\tt')
      ta.run_files(root, { 'core/x.go' }, 'abcdef0123')
      assert.is_true(noted('run in a terminal'))
      assert.equals(1, #jobs)
      assert.same({ 'go', 'test', './core' }, jobs[1].cmd)
      assert.same({}, ran)
    end)

    it(
      'leaves the choice to pytest-testmon when the project keeps it',
      function()
        restores[#restores + 1] = h.stub(
          ta,
          'has_adapter',
          function() return false end
        )
        h.write(root .. '/pyproject.toml')
        h.write(root .. '/.testmondata')
        fake('pytest', '')
        ta.run_files(root, { 'pkg/a.py' }, 'abcdef0123')
        assert.is_true(noted('by pytest%-testmon'))
        assert.same({ 'pytest', '--testmon' }, jobs[1].cmd)
      end
    )
  end)
end)
