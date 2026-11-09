local h = require('helpers')

describe('tools.deadcode', function()
  local deadcode, dir, root, cleanup, path, notes, restores, installed, trusted

  before_each(function()
    h.unload('tools.deadcode')
    deadcode = require('tools.deadcode')
    dir, cleanup = h.tmpdir()
    dir = vim.uv.fs_realpath(dir)
    root = dir .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root .. '/src', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, installed, trusted = {}, {}, true
    local util_root = require('util.root')
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
        ask = function() return trusted end,
      }),
      h.stub(
        package.loaded,
        'util.root',
        setmetatable(
          { contains = util_root.contains },
          { __call = function() return root end }
        )
      ),
    }
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    vim.cmd('silent! cclose')
    cleanup()
  end)

  --- A fake `name` that keeps its arguments, prints `out` and exits `code`
  local function fake(name, out, code)
    h.write(dir .. '/' .. name .. '.out', vim.split(out, '\n'))
    h.write(dir .. '/bin/' .. name, {
      '#!/bin/sh',
      'echo "$@" > "' .. dir .. '/' .. name .. '.args"',
      'cat "' .. dir .. '/' .. name .. '.out"',
      'exit ' .. (code or 0),
    })
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function noted(pattern)
    return vim.wait(3000, function()
      for _, note in ipairs(notes) do
        if note.msg:match(pattern) then return true end
      end
      return false
    end)
  end

  local KNIP = vim.json.encode({
    version = '2.1.0',
    runs = {
      {
        tool = { driver = { name = 'knip' } },
        results = {
          {
            ruleId = 'knip/exports',
            level = 'error',
            message = { text = 'Unused export: unused' },
            locations = {
              {
                physicalLocation = {
                  artifactLocation = { uri = 'src/a.js' },
                  region = { startLine = 2, startColumn = 14 },
                },
              },
            },
          },
        },
      },
    },
  })

  it('runs every tool that applies to a polyglot root', function()
    h.write(root .. '/package.json', { '{}' })
    h.write(root .. '/go.mod', { 'module example.com/s' })
    fake('knip', KNIP)
    fake('deadcode', 'main.go:5:6: unreachable func: unused')
    deadcode.run()
    assert.is_true(noted('2 unused'))
    local items = vim.fn.getqflist()
    assert.equals(2, #items)
    assert.equals(
      root .. '/src/a.js',
      vim.api.nvim_buf_get_name(items[1].bufnr)
    )
    assert.equals(2, items[1].lnum)
    assert.equals('[knip] Unused export: unused', items[1].text)
    assert.equals(root .. '/main.go', vim.api.nvim_buf_get_name(items[2].bufnr))
    assert.equals(6, items[2].col)
    assert.equals('[deadcode] unreachable func: unused', items[2].text)
    assert.matches(
      '%-%-reporter sarif',
      vim.fn.readfile(dir .. '/knip.args')[1]
    )
    assert.equals('Dead code', vim.fn.getqflist({ title = 0 }).title)
  end)

  it('lists only the tools of the project for completion', function()
    h.write(root .. '/requirements-dev.txt', { 'pytest' })
    h.write(root .. '/Cargo.toml', { '[package]' })
    assert.same({ 'vulture', 'cargo-machete' }, deadcode.complete())
  end)

  it('says so when every tool ran and found nothing', function()
    h.write(root .. '/go.mod', { 'module example.com/s' })
    fake('deadcode', '')
    deadcode.run()
    assert.is_true(noted('^No dead code %(deadcode%)$'))
  end)

  it(
    'has Mason install a missing tool and never says nothing was found',
    function()
      h.write(root .. '/go.mod', { 'module example.com/s' })
      h.write(root .. '/setup.py', { '' })
      fake('vulture', '')
      deadcode.run()
      assert.is_true(noted('deadcode is not installed'))
      assert.same({ 'deadcode' }, installed)
      assert.is_false(noted('No dead code'))
    end
  )

  it('reports a failed run, keeping what was found', function()
    h.write(root .. '/setup.py', { '' })
    -- 1: a file it could not parse
    fake('vulture', "m.py:6: unused function 'never' (60% confidence)", 1)
    deadcode.run('vulture')
    assert.is_true(noted('vulture exited 1'))
    assert.equals(1, #vim.fn.getqflist())
    assert.matches(
      '%-%-min%-confidence 60',
      vim.fn.readfile(dir .. '/vulture.args')[1]
    )
  end)

  it('does not run knip in a project not trusted', function()
    h.write(root .. '/package.json', { '{}' })
    fake('knip', KNIP)
    trusted = false
    deadcode.run()
    assert.is_true(noted('knip not run'))
    assert.equals(0, vim.fn.filereadable(dir .. '/knip.args'))
    assert.is_false(noted('No dead code'))
  end)

  it('points cargo-machete at the line declaring the dependency', function()
    h.write(root .. '/Cargo.toml', {
      '[package]',
      'name = "s"',
      '',
      '[dependencies]',
      'serde = "1"',
      'log = "0.4"',
    })
    local items = deadcode.cargo_machete(
      table.concat({
        'cargo-machete found the following unused dependencies in this directory:',
        's -- ./Cargo.toml:',
        '\tlog',
        '',
        'Done!',
      }, '\n'),
      root
    )
    assert.equals(1, #items)
    assert.equals(root .. '/Cargo.toml', items[1].filename)
    assert.equals(6, items[1].lnum)
    assert.equals('[cargo-machete] unused dependency: log', items[1].text)
  end)

  it('opens no file outside the project', function()
    local items = deadcode.vulture('../../etc/x.py:1: unused import', root)
    assert.is_nil(items[1].filename)
    assert.matches('outside the project', items[1].text)
  end)
end)
