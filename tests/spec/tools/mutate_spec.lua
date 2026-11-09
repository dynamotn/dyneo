local h = require('helpers')

describe('tools.mutate', function()
  local mutate, dir, root, cleanup, path, notes, restores, installed
  local trusted, asked, jobs, exit_code, on_job

  before_each(function()
    h.unload('tools.mutate')
    mutate = require('tools.mutate')
    dir, cleanup = h.tmpdir()
    root = dir .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root .. '/src', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, installed, jobs, asked = {}, {}, {}, 0
    trusted, exit_code, on_job = true, 0, nil
    local stdpath = vim.fn.stdpath
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(package.loaded, 'util.lazy_install', {
        install_once = function(name) table.insert(installed, name) end,
      }),
      h.stub(package.loaded, 'util.trust', {
        ask = function()
          asked = asked + 1
          return trusted
        end,
      }),
      h.stub(vim.fn, 'jobstart', function(cmd, opts)
        table.insert(jobs, { cmd = cmd, opts = opts })
        if on_job then on_job(cmd) end
        opts.on_exit(1, exit_code)
        return 1
      end),
      h.stub(
        vim.fn,
        'stdpath',
        function(what)
          return what == 'cache' and dir .. '/cache' or stdpath(what)
        end
      ),
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
    vim.fn.setqflist({})
    vim.diagnostic.reset(mutate.NS)
    cleanup()
  end)

  local function fake(name)
    h.write(dir .. '/bin/' .. name, { '#!/bin/sh', 'exit 0' })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function noted(pattern, level)
    return vim.wait(2000, function()
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

  local function diagnostics()
    local list = vim.diagnostic.get(nil, { namespace = mutate.NS })
    table.sort(list, function(a, b) return a.lnum < b.lnum end)
    return list
  end

  local CARGO = {
    outcomes = {
      { scenario = 'Baseline', summary = 'Success' },
      {
        scenario = {
          Mutant = {
            name = 'src/lib.rs:2:7: replace + with * in add',
            file = 'src/lib.rs',
            span = {
              start = { line = 2, column = 7 },
              ['end'] = { line = 2, column = 8 },
            },
            replacement = '*',
          },
        },
        summary = 'MissedMutant',
      },
      {
        scenario = {
          Mutant = {
            name = 'src/lib.rs:6:5: replace is_big -> bool with true',
            file = 'src/lib.rs',
            span = {
              start = { line = 6, column = 5 },
              ['end'] = { line = 6, column = 11 },
            },
          },
        },
        summary = 'CaughtMutant',
      },
      {
        scenario = {
          Mutant = {
            name = 'src/lib.rs:6:7: replace > with >= in is_big',
            file = 'src/lib.rs',
            span = {
              start = { line = 6, column = 7 },
              ['end'] = { line = 6, column = 8 },
            },
          },
        },
        summary = 'Timeout',
      },
    },
  }

  it('reads the mutants of a Stryker report', function()
    local mutants = mutate.stryker({
      schemaVersion = '1',
      files = {
        ['src/calc.ts'] = {
          language = 'typescript',
          source = 'export function add(a, b) {\n  return a + b;\n}\n',
          mutants = {
            {
              id = '1',
              mutatorName = 'ArithmeticOperator',
              replacement = 'a - b',
              status = 'Survived',
              location = {
                start = { line = 2, column = 10 },
                ['end'] = { line = 2, column = 15 },
              },
            },
            {
              id = '2',
              mutatorName = 'BlockStatement',
              replacement = '{}',
              status = 'NoCoverage',
              location = {
                start = { line = 1, column = 27 },
                ['end'] = { line = 3, column = 2 },
              },
            },
            {
              id = '3',
              mutatorName = 'X',
              status = 'Killed',
              location = { start = { line = 1, column = 1 } },
            },
          },
        },
      },
    })
    assert.same({
      file = 'src/calc.ts',
      lnum = 2,
      col = 10,
      end_lnum = 2,
      end_col = 15,
      status = 'survived',
      text = 'ArithmeticOperator: a + b -> a - b',
    }, mutants[1])
    -- Over several lines: the mutator alone
    assert.same('nocoverage', mutants[2].status)
    assert.same('BlockStatement', mutants[2].text)
    assert.same('killed', mutants[3].status)
  end)

  it('reads the mutants of cargo-mutants, not its baseline', function()
    local mutants = mutate.cargo_mutants(CARGO)
    assert.same(3, #mutants)
    assert.same({
      file = 'src/lib.rs',
      lnum = 2,
      col = 7,
      end_lnum = 2,
      end_col = 8,
      status = 'survived',
      text = 'replace + with * in add',
    }, mutants[1])
    assert.same('killed', mutants[2].status)
    assert.same('timeout', mutants[3].status)
  end)

  it('reads the mutants of gremlins', function()
    local mutants = mutate.gremlins({
      files = {
        {
          file_name = 'calc.go',
          mutations = {
            {
              type = 'CONDITIONALS_BOUNDARY',
              status = 'LIVED',
              line = 8,
              column = 11,
            },
            {
              type = 'ARITHMETIC_BASE',
              status = 'NOT COVERED',
              line = 12,
              column = 11,
            },
            { type = 'X', status = 'NOT VIABLE', line = 3, column = 1 },
          },
        },
      },
    })
    assert.same({
      file = 'calc.go',
      lnum = 8,
      col = 11,
      status = 'survived',
      text = 'conditionals boundary',
    }, mutants[1])
    assert.same('nocoverage', mutants[2].status)
    assert.same('other', mutants[3].status)
  end)

  it('names the mutmut module of a file', function()
    assert.same('calc', mutate.python_module('src/calc/__init__.py'))
    assert.same('calc.ops', mutate.python_module('src/calc/ops.py'))
    assert.same('app', mutate.python_module('app.py'))
  end)

  --- A project mutmut ran on: the copy under `mutants/` as mutmut 3.8
  --- writes it, with its `.meta` and `.spans`
  local function mutmut_project()
    h.write(root .. '/pyproject.toml', { '[tool.mutmut]' })
    h.write(root .. '/src/calc/__init__.py', {
      'def add(a, b):', -- 1
      '    return a + b',
      '',
      '',
      'def is_big(n):', -- 5
      '    if n > 10:',
      '        return True',
      '    return False',
      '',
      '',
      'class Box:', -- 11
      '    def __init__(self, n):',
      '        self.n = n',
    })
    local copy = {
      'from mutmut.mutation.trampoline import wrap_in_trampoline', -- 1
      '@_mutmut_mutated(mutants_x_add__mutmut)',
      'def add(a, b):',
      '    return a + b',
      'def x_add__mutmut_orig(a, b):', -- 5
      '    return a + b',
      'def x_add__mutmut_1(a, b):',
      '    return a - b',
      '',
      '',
      'def x_is_big__mutmut_orig(n):', -- 11
      '    if n > 10:',
      '        return True',
      '    return False',
      '',
      '',
      'def x_is_big__mutmut_1(n):', -- 17
      '    if n > 11:',
      '        return True',
      '    return False',
      'class Box:', -- 21
      '    def xǁBoxǁ__init____mutmut_orig(self, n):',
      '        self.n = n',
      '    def xǁBoxǁ__init____mutmut_1(self, n):',
      '        self.n = None',
    }
    h.write(root .. '/mutants/src/calc/__init__.py', copy)
    h.write(root .. '/mutants/src/calc/__init__.py.spans', {
      vim.json.encode({
        version = 1,
        spans = {
          x_add__mutmut_orig = { 5, 6 },
          x_add__mutmut_1 = { 7, 8 },
          x_is_big__mutmut_orig = { 9, 14 },
          x_is_big__mutmut_1 = { 15, 20 },
          ['xǁBoxǁ__init____mutmut_orig'] = { 22, 23 },
          ['xǁBoxǁ__init____mutmut_1'] = { 24, 25 },
        },
      }),
    })
    h.write(root .. '/mutants/src/calc/__init__.py.meta', {
      vim.json.encode({
        exit_code_by_key = {
          ['calc.x_add__mutmut_1'] = 1,
          ['calc.x_is_big__mutmut_1'] = 0,
          ['calc.xǁBoxǁ__init____mutmut_1'] = 33,
        },
      }),
    })
  end

  it('places the mutants of mutmut on the lines of the source', function()
    mutmut_project()
    local mutants = assert(mutate.read_mutmut(root))
    table.sort(mutants, function(a, b) return a.lnum < b.lnum end)
    assert.same({
      file = 'src/calc/__init__.py',
      lnum = 2,
      col = 14,
      status = 'killed',
      text = 'return a + b -> return a - b (calc.x_add__mutmut_1)',
    }, mutants[1])
    assert.same({
      file = 'src/calc/__init__.py',
      lnum = 6,
      col = 13,
      status = 'survived',
      text = 'if n > 10: -> if n > 11: (calc.x_is_big__mutmut_1)',
    }, mutants[2])
    -- A method: found below its class
    assert.same(13, mutants[3].lnum)
    assert.same('nocoverage', mutants[3].status)
  end)

  it('says when there are no mutmut results', function()
    local mutants, err = mutate.read_mutmut(root)
    assert.is_nil(mutants)
    assert.matches('No mutmut results', err)
  end)

  it('marks survivors as warnings and the unreached as hints', function()
    h.write(root .. '/src/lib.rs', vim.fn['repeat']({ 'x' }, 10))
    mutate.show('cargo-mutants', root, mutate.cargo_mutants(CARGO))
    local list = diagnostics()
    assert.same(2, #list)
    assert.same(1, list[1].lnum)
    assert.same(6, list[1].col)
    assert.same(vim.diagnostic.severity.WARN, list[1].severity)
    assert.matches('survived: replace %+ with %* in add', list[1].message)
    assert.same(5, list[2].lnum)
    assert.same(vim.diagnostic.severity.INFO, list[2].severity)
    assert.matches('timed out', list[2].message)
    local qf = vim.fn.getqflist({ title = 1, items = 1 })
    assert.same('Mutants', qf.title)
    assert.same(2, #qf.items)
    assert.is_true(
      noted('1 survived, 0 no test reaches, 1 timed out, 1 killed')
    )

    mutate.clear()
    assert.same(0, #diagnostics())
    assert.same(0, #vim.fn.getqflist())
  end)

  it('says none survived only from a report of killed mutants', function()
    mutate.show('gremlins', root, {
      { file = 'a.go', lnum = 1, status = 'killed', text = 'x' },
    })
    assert.is_true(noted('No mutant survived'))
    notes = {}
    mutate.show('gremlins', root, {})
    assert.is_true(noted('holds no mutant', vim.log.levels.WARN))
    assert.is_false(noted('No mutant survived'))
  end)

  --- A Rust buffer of the project
  local function rust_buffer()
    h.write(root .. '/Cargo.toml', { '[package]' })
    h.write(root .. '/src/lib.rs', vim.fn['repeat']({ 'x' }, 10))
    vim.cmd.edit(root .. '/src/lib.rs')
    vim.bo.filetype = 'rust'
  end

  it('runs the tool in a terminal and loads its report', function()
    rust_buffer()
    fake('cargo-mutants')
    on_job = function()
      h.write(root .. '/mutants.out/outcomes.json', { vim.json.encode(CARGO) })
    end
    exit_code = 2
    mutate.run(true)
    assert.same(1, #jobs)
    assert.same(
      { 'cargo-mutants', 'mutants', '--file', 'src/lib.rs' },
      jobs[1].cmd
    )
    assert.same(root, jobs[1].opts.cwd)
    assert.is_true(jobs[1].opts.term)
    assert.is_true(vim.wait(2000, function() return #diagnostics() == 2 end))
  end)

  it('loads no report after a failed run', function()
    rust_buffer()
    fake('cargo-mutants')
    h.write(root .. '/mutants.out/outcomes.json', { vim.json.encode(CARGO) })
    exit_code = 4
    mutate.run()
    assert.is_true(noted('exited 4', vim.log.levels.ERROR))
    assert.same(0, #diagnostics())
  end)

  it('says so when a run wrote no report', function()
    rust_buffer()
    fake('cargo-mutants')
    mutate.run()
    assert.is_true(noted('no readable report', vim.log.levels.ERROR))
  end)

  it('runs nothing in a project not trusted', function()
    rust_buffer()
    fake('cargo-mutants')
    trusted = false
    mutate.run()
    assert.same(1, asked)
    assert.same(0, #jobs)
    assert.is_true(noted('not trusted'))
  end)

  it('offers to install a missing tool, before asking anything', function()
    rust_buffer()
    mutate.run()
    assert.same({ 'cargo-mutants' }, installed)
    assert.same(0, asked)
    assert.same(0, #jobs)
    assert.is_true(noted('not installed', vim.log.levels.ERROR))
  end)

  it("asks for the project's own Stryker", function()
    h.write(root .. '/package.json', { '{}' })
    h.write(root .. '/src/a.ts', { 'x' })
    vim.cmd.edit(root .. '/src/a.ts')
    vim.bo.filetype = 'typescript'
    mutate.run()
    assert.same({}, installed)
    assert.is_true(noted('npm install', vim.log.levels.ERROR))
  end)

  it(
    'makes the files of a run on one Go package relative to the module',
    function()
      h.write(root .. '/go.mod', { 'module x' })
      h.write(root .. '/sub/sub.go', { 'package sub', '', 'x', 'y' })
      vim.cmd.edit(root .. '/sub/sub.go')
      vim.bo.filetype = 'go'
      fake('gremlins')
      on_job = function(cmd)
        h.write(cmd[4], {
          vim.json.encode({
            files = {
              {
                file_name = 'sub.go',
                mutations = {
                  { type = 'X', status = 'LIVED', line = 3, column = 1 },
                },
              },
            },
          }),
        })
      end
      mutate.run(true)
      assert.same('./sub', jobs[1].cmd[5])
      vim.wait(2000, function() return #vim.fn.getqflist() > 0 end)
      local items = vim.fn.getqflist()
      assert.same(1, #items)
      assert.same(
        root .. '/sub/sub.go',
        vim.api.nvim_buf_get_name(items[1].bufnr)
      )
      -- And again, from the report alone
      mutate.clear()
      mutate.load()
      assert.same(1, #vim.fn.getqflist())
    end
  )

  it('refuses a buffer outside the project for a run on one file', function()
    rust_buffer()
    fake('cargo-mutants')
    vim.cmd.enew()
    vim.bo.filetype = 'rust'
    local util_root = require('util.root')
    table.insert(
      restores,
      h.stub(
        package.loaded,
        'util.root',
        setmetatable(
          { contains = util_root.contains },
          { __call = function() return root end }
        )
      )
    )
    mutate.run(true)
    assert.same(0, #jobs)
    assert.is_true(noted('not a source file', vim.log.levels.ERROR))
  end)

  it('defines :DyMutate', function()
    dofile(h.root .. '/plugin/mutate.lua')
    h.write(root .. '/Cargo.toml', { '[package]' })
    vim.cmd.edit(root .. '/Cargo.toml')
    local util_root = require('util.root')
    table.insert(
      restores,
      h.stub(
        package.loaded,
        'util.root',
        setmetatable(
          { contains = util_root.contains },
          { __call = function() return root end }
        )
      )
    )
    package.loaded['tools.mutate'] = mutate
    vim.cmd('DyMutate load')
    assert.is_true(noted('No report at', vim.log.levels.ERROR))
    vim.cmd('DyMutate nope')
    assert.is_true(noted('Unknown argument: nope'))
  end)
end)
