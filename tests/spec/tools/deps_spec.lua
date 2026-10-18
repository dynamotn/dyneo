local h = require('helpers')

describe('tools.deps', function()
  local deps, dir, cleanup

  before_each(function()
    h.unload('tools.deps')
    deps = require('tools.deps')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function()
    vim.cmd('cclose | silent! %bwipeout!')
    cleanup()
  end)

  it('reads the violations of dependency-cruiser', function()
    local items = deps.depcruise(
      vim.json.encode({
        {
          from = 'src/ui/a.ts',
          to = 'src/db/b.ts',
          rule = { name = 'no-ui-to-db', severity = 'error' },
        },
        {
          from = 'src/x.ts',
          to = 'src/y.ts',
          rule = { name = 'no-circular', severity = 'warn' },
          cycle = { { name = 'src/y.ts' }, { name = 'src/x.ts' } },
        },
        {
          from = 'src/old.ts',
          to = 'src/y.ts',
          rule = { name = 'known', severity = 'ignore' },
        },
      }),
      '/p'
    )
    assert.equals(2, #items)
    assert.same({
      filename = '/p/src/ui/a.ts',
      lnum = 1,
      type = 'E',
      text = 'no-ui-to-db: src/ui/a.ts → src/db/b.ts',
    }, items[1])
    assert.equals(
      'no-circular: src/x.ts → src/y.ts (cycle: src/y.ts → src/x.ts)',
      items[2].text
    )
    assert.equals('W', items[2].type)
    assert.is_nil(deps.depcruise('not json', '/p'))
    -- The whole cruise result is not what is asked for
    assert.is_nil(deps.depcruise('{"summary":{"violations":[]}}', '/p'))
    assert.same({}, deps.depcruise('[]', '/p'))
  end)

  it('asks dependency-cruiser for its violations alone', function()
    h.write(dir .. '/.dependency-cruiser.cjs', {})
    local cmd = deps.TOOLS[1].cmd(dir)
    assert.same({ 'depcruise', '--output-type', 'baseline', '.' }, cmd)
  end)

  it('reads the warnings of go-arch-lint, at their line', function()
    local items = deps.go_arch_lint(
      vim.json.encode({
        Type = 'models.Check',
        Payload = {
          ArchWarningsDeps = {
            {
              ComponentName = 'c',
              FileRelativePath = '/internal/c/c1.go',
              ResolvedImportName = 'x/internal/a',
              Reference = {
                Valid = true,
                File = '/p/internal/c/c1.go',
                Line = 3,
                Offset = 8,
              },
            },
          },
          ArchWarningsNotMatched = {
            {
              FileRelativePath = '/cmd/main.go',
              FileAbsolutePath = '/p/cmd/main.go',
            },
          },
        },
      }),
      '/p'
    )
    assert.same({
      {
        filename = '/p/internal/c/c1.go',
        lnum = 3,
        col = 8,
        type = 'E',
        text = 'c may not depend on x/internal/a',
      },
      {
        filename = '/p/cmd/main.go',
        lnum = 1,
        type = 'W',
        text = 'In no component of .go-arch-lint.yml',
      },
    }, items)
  end)

  it(
    'reads deep-scan warnings and unknown references of go-arch-lint',
    function()
      local items, note = deps.go_arch_lint(
        vim.json.encode({
          Payload = {
            ArchWarningsDeps = {
              {
                ComponentName = 'c',
                FileAbsolutePath = '/p/c.go',
                ResolvedImportName = 'a',
                Reference = { Valid = false, File = '', Line = 0 },
              },
            },
            ArchWarningsDeepScan = {
              {
                Gate = {
                  ComponentName = 'operations',
                  MethodName = 'NewOperation',
                  Definition = { Valid = true, File = '/p/op.go', Line = 54 },
                },
                Dependency = {
                  ComponentName = 'repository',
                  Name = 'micro.ViewRepository',
                  Injection = {
                    Valid = true,
                    File = '/p/container/cmd_mapping.go',
                    Line = 15,
                    Offset = 4,
                  },
                },
              },
            },
            OmittedCount = 3,
          },
        }),
        '/p'
      )
      assert.same({
        {
          filename = '/p/c.go',
          lnum = 1,
          col = 0,
          type = 'E',
          text = 'c may not depend on a',
        },
        {
          filename = '/p/container/cmd_mapping.go',
          lnum = 15,
          col = 4,
          type = 'E',
          text = 'operations may not be given repository (micro.ViewRepository to NewOperation)',
        },
      }, items)
      assert.equals('3 more not shown', note)
      local _, none = deps.go_arch_lint('{"Payload":{"OmittedCount":0}}', '/p')
      assert.is_nil(none)
    end
  )

  it(
    'points a deep-scan warning at the gate when the injection is not valid',
    function()
      local items = deps.go_arch_lint(
        vim.json.encode({
          Payload = {
            ArchWarningsDeepScan = {
              {
                Gate = {
                  ComponentName = 'g',
                  MethodName = 'New',
                  Definition = {
                    Valid = true,
                    File = 'g.go',
                    Line = 3,
                    Offset = 2,
                  },
                },
                Dependency = {
                  ComponentName = 'd',
                  Name = 'db',
                  Injection = { Valid = false, File = '' },
                },
              },
            },
          },
        }),
        '/p'
      )
      assert.same({
        {
          filename = '/p/g.go',
          lnum = 3,
          col = 2,
          type = 'E',
          text = 'g may not be given d (db to New)',
        },
      }, items)
    end
  )

  it('points an import of a module it cannot find at the root', function()
    local items = deps.import_linter(
      'shop.low must not import shop.high:\n-   shop.low.red -> shop.high.x (l.2)',
      dir
    )
    assert.equals(dir, items[1].filename)
    assert.equals(
      'shop.low must not import shop.high: shop.low.red → shop.high.x',
      items[1].text
    )
  end)

  it('reads the broken contracts of import-linter', function()
    h.write(dir .. '/src/shop/low/blue.py', {})
    local items = deps.import_linter(
      table.concat({
        'Broken contracts',
        '----------------',
        '',
        'Layers',
        '------',
        '',
        'shop.low is not allowed to import shop.high:',
        '',
        '-   shop.low.blue -> shop.high.yellow (l.6)',
      }, '\n'),
      dir
    )
    assert.same({
      {
        filename = dir .. '/src/shop/low/blue.py',
        lnum = 6,
        type = 'E',
        text = 'shop.low is not allowed to import shop.high: shop.low.blue → shop.high.yellow',
      },
    }, items)
  end)

  it('finds the tool a project is set up for', function()
    h.write(dir .. '/pyproject.toml', { '[project]', 'name = "x"' })
    h.write(dir .. '/pkg/a.py', {})
    vim.cmd.edit(dir .. '/pkg/a.py')
    assert.is_nil(deps.find(0))
    h.write(
      dir .. '/pyproject.toml',
      { '[tool.importlinter]', 'root_package = "pkg"' }
    )
    local tool, root = deps.find(0)
    assert.equals('import-linter', tool.name)
    assert.equals(dir, root)
  end)

  it('finds the nearest configuration, whichever tool it is for', function()
    h.write(dir .. '/.dependency-cruiser.json', {})
    h.write(dir .. '/svc/.go-arch-lint.yml', { 'version: 3' })
    h.write(dir .. '/svc/main.go', {})
    vim.cmd.edit(dir .. '/svc/main.go')
    local tool, root = deps.find(0)
    assert.equals('go-arch-lint', tool.name)
    assert.equals(dir .. '/svc', root)
    -- Two in one directory: the first listed
    h.write(dir .. '/svc/.dependency-cruiser.ts', {})
    tool, root = deps.find(0)
    assert.equals('dependency-cruiser', tool.name)
    assert.equals(dir .. '/svc', root)
  end)

  it('looks past a pyproject.toml that sets up no import-linter', function()
    h.write(dir .. '/pyproject.toml', { '[tool.importlinter]' })
    h.write(dir .. '/lib/pyproject.toml', { '[project]', 'name = "lib"' })
    h.write(dir .. '/lib/a.py', {})
    vim.cmd.edit(dir .. '/lib/a.py')
    local tool, root = deps.find(0)
    assert.equals('import-linter', tool.name)
    assert.equals(dir, root)
  end)

  it("runs the project's own import-linter first", function()
    local tool = deps.TOOLS[3]
    assert.same({ 'lint-imports' }, tool.cmd(dir))
    h.write(dir .. '/.venv/bin/lint-imports', { '#!/bin/sh' })
    vim.fn.setfperm(dir .. '/.venv/bin/lint-imports', 'rwxr-xr-x')
    assert.same({ dir .. '/.venv/bin/lint-imports' }, tool.cmd(dir))
  end)

  describe('check', function()
    local notes, restore, restore_confirm, path, answer

    before_each(function()
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg, level }) end
      )
      h.unload('util.trust')
      vim.fn.setqflist({}, 'f')
      answer = 1
      restore_confirm = h.stub(vim.fn, 'confirm', function() return answer end)
      path = vim.env.PATH
      h.write(dir .. '/.go-arch-lint.yml', { 'version: 3' })
      h.write(dir .. '/main.go', { 'package main' })
      vim.cmd.edit(dir .. '/main.go')
    end)
    after_each(function()
      restore()
      restore_confirm()
      vim.env.PATH = path
    end)

    ---@param body string[]
    local function fake(body)
      local bin = dir .. '/bin'
      h.write(bin .. '/go-arch-lint', vim.list_extend({ '#!/bin/sh' }, body))
      vim.fn.setfperm(bin .. '/go-arch-lint', 'rwxr-xr-x')
      vim.env.PATH = bin .. ':' .. path
    end

    it('puts what breaks in the quickfix list', function()
      fake({
        [[echo '{"Payload":{"ArchWarningsDeps":[{"ComponentName":"c","ResolvedImportName":"a","Reference":{"File":"]]
          .. dir
          .. [[/main.go","Line":1}}]}}']],
        'exit 1',
      })
      deps.check()
      vim.wait(5000, function() return #vim.fn.getqflist() > 0 end)
      assert.equals('c may not depend on a', vim.fn.getqflist()[1].text)
      assert.same(
        { '1 rules broken (go-arch-lint)', vim.log.levels.WARN },
        notes[#notes]
      )
    end)

    it('counts deep-scan warnings and says how many were left out', function()
      fake({
        [[echo '{"Payload":{"ArchWarningsDeepScan":[{"Gate":{"ComponentName":"g"},"Dependency":{"ComponentName":"d","Injection":{"Valid":true,"File":"main.go","Line":1}}}],"OmittedCount":2}}']],
        'exit 1',
      })
      deps.check()
      vim.wait(5000, function() return #vim.fn.getqflist() > 0 end)
      assert.same({
        '1 rules broken (go-arch-lint); 2 more not shown',
        vim.log.levels.WARN,
      }, notes[#notes])
    end)

    it('says a failed run failed, never that nothing broke', function()
      fake({ 'echo "bad config" >&2', 'exit 2' })
      deps.check()
      vim.wait(5000, function() return #notes > 1 end)
      assert.same(
        { 'go-arch-lint failed: bad config', vim.log.levels.ERROR },
        notes[#notes]
      )
    end)

    it('runs nothing of a project the user did not trust', function()
      fake({ 'touch "$0.ran"' })
      answer = 2
      deps.check()
      assert.same(
        { 'go-arch-lint not run', vim.log.levels.WARN },
        notes[#notes]
      )
      vim.wait(200)
      assert.is_nil(vim.uv.fs_stat(dir .. '/bin/go-arch-lint.ran'))
    end)

    it('says when the project has no rules', function()
      vim.fn.delete(dir .. '/.go-arch-lint.yml')
      deps.check()
      assert.equals(vim.log.levels.WARN, notes[1][2])
      assert.is_truthy(notes[1][1]:find('No dependency rules here', 1, true))
    end)

    it('says when the tool is not installed', function()
      vim.env.PATH = dir .. '/bin'
      deps.check()
      vim.wait(5000, function() return #notes > 1 end)
      assert.equals(vim.log.levels.ERROR, notes[#notes][2])
      assert.is_truthy(notes[#notes][1]:find('go-arch-lint', 1, true))
      assert.same({}, vim.fn.getqflist())
    end)

    it('says when nothing breaks', function()
      fake({ [[echo '{"Payload":{}}']] })
      deps.check()
      vim.wait(5000, function() return #notes > 1 end)
      assert.equals('No rule broken (go-arch-lint)', notes[#notes][1])
    end)
  end)
end)
