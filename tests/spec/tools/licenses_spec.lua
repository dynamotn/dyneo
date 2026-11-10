local h = require('helpers')

describe('tools.licenses', function()
  local licenses, dir, cleanup, path, notes, restores, installed

  before_each(function()
    h.unload('tools.licenses')
    licenses = require('tools.licenses')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(dir .. '/proj', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, installed = {}, nil
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(package.loaded, 'util.lazy_install', {
        install_once = function(name) installed = name end,
      }),
    }
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    while #vim.api.nvim_list_tabpages() > 1 do
      vim.cmd('tabclose!')
    end
    cleanup()
  end)

  ---@param pattern string
  local function noted(pattern)
    local found
    vim.wait(3000, function()
      for _, note in ipairs(notes) do
        if note.msg:find(pattern) then
          found = note
          return true
        end
      end
      return false
    end)
    return found
  end

  local CYCLONEDX = {
    bomFormat = 'CycloneDX',
    specVersion = '1.5',
    components = {
      { type = 'application', name = 'package-lock.json' },
      {
        type = 'library',
        name = 'left-pad',
        version = '1.3.0',
        purl = 'pkg:npm/left-pad@1.3.0',
        licenses = { { license = { id = 'MIT' } } },
      },
      {
        type = 'library',
        name = 'node-forge',
        version = '1.3.1',
        purl = 'pkg:npm/node-forge@1.3.1',
        licenses = { { expression = 'BSD-3-Clause OR GPL-2.0-only' } },
      },
      {
        type = 'library',
        name = 'readline',
        version = '8.0.0',
        purl = 'pkg:npm/readline@8.0.0',
        licenses = { { license = { id = 'GPL-3.0-only' } } },
      },
      {
        type = 'library',
        name = 'core',
        group = '@scope',
        version = '2.0.0',
        purl = 'pkg:npm/%40scope/core@2.0.0',
      },
    },
  }

  local SPDX = {
    spdxVersion = 'SPDX-2.3',
    packages = {
      { name = '.', licenseConcluded = 'NOASSERTION' },
      {
        name = 'serde',
        versionInfo = '1.0.0',
        licenseConcluded = 'NOASSERTION',
        licenseDeclared = 'MIT OR Apache-2.0',
        externalRefs = {
          {
            referenceType = 'purl',
            referenceLocator = 'pkg:cargo/serde@1.0.0',
          },
        },
      },
      {
        name = 'mystery',
        versionInfo = '0.1.0',
        licenseConcluded = 'NOASSERTION',
        licenseDeclared = 'NOASSERTION',
        externalRefs = {
          {
            referenceType = 'purl',
            referenceLocator = 'pkg:cargo/mystery@0.1.0',
          },
        },
      },
    },
  }

  describe('evaluate', function()
    it('passes OR when any side passes, AND only when all do', function()
      assert.equals('allow', licenses.evaluate('MIT OR GPL-3.0-only'))
      assert.equals('deny', licenses.evaluate('MIT AND GPL-3.0-only'))
      assert.equals('warn', licenses.evaluate('MIT AND MPL-2.0'))
      assert.equals('warn', licenses.evaluate('GPL-2.0 OR LGPL-2.1'))
    end)

    it('binds AND tighter than OR, and follows parentheses', function()
      assert.equals('allow', licenses.evaluate('MIT OR GPL-3.0 AND ISC'))
      assert.equals('deny', licenses.evaluate('(MIT OR GPL-3.0) AND AGPL-3.0'))
      assert.equals(
        'allow',
        licenses.evaluate('((Apache-2.0)) AND (ISC OR SSPL-1.0)')
      )
    end)

    it('keeps a WITH exception as part of the id', function()
      local expression = 'GPL-2.0-only WITH Classpath-exception-2.0'
      assert.equals('deny', licenses.evaluate(expression))
      assert.equals(
        'allow',
        licenses.evaluate(expression, { allow = { expression } })
      )
      assert.equals('allow', licenses.evaluate('MIT OR ' .. expression))
    end)

    it('reviews what is unknown or not an expression', function()
      assert.equals('warn', licenses.evaluate(nil))
      assert.equals('warn', licenses.evaluate('NOASSERTION'))
      assert.equals('warn', licenses.evaluate('EPL-2.0'))
      assert.equals('warn', licenses.evaluate('MIT OR'))
      assert.equals('warn', licenses.evaluate('(MIT'))
      assert.equals('allow', licenses.evaluate('mit'))
    end)
  end)

  describe('packages', function()
    it('reads CycloneDX ids, names and expressions', function()
      local packages = assert(licenses.packages(CYCLONEDX))
      assert.equals(4, #packages)
      assert.same({ 'MIT' }, packages[1].licenses)
      assert.same({ 'BSD-3-Clause OR GPL-2.0-only' }, packages[2].licenses)
      assert.equals('@scope/core', packages[4].name)
      assert.same({}, packages[4].licenses)
    end)

    it('reads SPDX, the declared license when none is concluded', function()
      local packages = assert(licenses.packages(SPDX))
      assert.equals(2, #packages)
      assert.same({ 'MIT OR Apache-2.0' }, packages[1].licenses)
      assert.same({}, packages[2].licenses)
    end)

    it('refuses a document of neither kind', function()
      local packages, err = licenses.packages({ hello = 'world' })
      assert.is_nil(packages)
      assert.matches('neither', err)
    end)
  end)

  describe('project_rules', function()
    it('reads the lists of .nvim/licenses.json', function()
      h.write(
        dir .. '/proj/.nvim/licenses.json',
        { '{ "allow": ["LGPL-2.1-only"], "deny": ["WTFPL"] }' }
      )
      local rules = assert(licenses.project_rules(dir .. '/proj'))
      assert.equals('allow', licenses.evaluate('LGPL-2.1-only', rules))
      assert.equals('deny', licenses.evaluate('WTFPL', rules))
      assert.equals('warn', licenses.evaluate('LGPL-3.0-only', rules))
    end)

    it('says why a malformed file cannot be used', function()
      h.write(dir .. '/proj/.nvim/licenses.json', { '{ "allow": [' })
      local rules, err = licenses.project_rules(dir .. '/proj')
      assert.is_nil(rules)
      assert.matches('not a JSON object', err)
      h.write(dir .. '/proj/.nvim/licenses.json', { '{ "allow": "MIT" }' })
      rules, err = licenses.project_rules(dir .. '/proj')
      assert.is_nil(rules)
      assert.matches('not a list', err)
      h.write(dir .. '/proj/.nvim/licenses.json', { '{ "permit": [] }' })
      assert.matches(
        'unknown key',
        select(2, licenses.project_rules(dir .. '/proj'))
      )
    end)

    it(
      'is nil without a file',
      function() assert.is_nil(licenses.project_rules(dir .. '/proj')) end
    )
  end)

  describe('locate', function()
    local function item(purl)
      return { name = 'x', version = '1.0.0', purl = purl, licenses = {} }
    end

    it('finds the manifest line of a direct dependency', function()
      local root = dir .. '/proj'
      h.write(root .. '/package.json', {
        '{',
        '  "name": "demo",',
        '  "dependencies": {',
        '    "@scope/core": "^2.0.0",',
        '    "node-forge": "1.3.1"',
        '  }',
        '}',
      })
      h.write(root .. '/go.mod', {
        'module example.com/demo',
        '',
        'require (',
        '\tgithub.com/foo/bar v1.2.3',
        ')',
      })
      h.write(root .. '/Cargo.toml', {
        '[package]',
        'name = "demo"',
        '[dependencies]',
        'serde = "1"',
        '[dependencies.tokio]',
        'version = "1"',
      })
      h.write(root .. '/requirements.txt', { '# pins', 'Requests==2.31.0' })
      h.write(root .. '/pyproject.toml', {
        '[project]',
        'dependencies = ["flask>=3", "Typing_Extensions"]',
      })
      local cache = {}
      local function at(purl)
        local where = licenses.locate(root, item(purl), cache)
        return where and vim.fs.basename(where.filename) .. ':' .. where.lnum
      end
      assert.equals('package.json:4', at('pkg:npm/%40scope/core@2.0.0'))
      assert.equals('package.json:5', at('pkg:npm/node-forge@1.3.1'))
      assert.equals('go.mod:4', at('pkg:golang/github.com/foo/bar@v1.2.3'))
      assert.equals('Cargo.toml:4', at('pkg:cargo/serde@1.0.0'))
      assert.equals('Cargo.toml:5', at('pkg:cargo/tokio@1.0.0'))
      assert.equals('pyproject.toml:2', at('pkg:pypi/typing-extensions@4'))
      assert.equals('requirements.txt:2', at('pkg:pypi/requests@2.31.0'))
    end)

    it('falls back to the lockfile entry, then the manifest', function()
      local root = dir .. '/proj'
      h.write(root .. '/package.json', { '{ "name": "demo" }' })
      h.write(root .. '/package-lock.json', {
        '{',
        '  "lockfileVersion": 3,',
        '  "packages": {',
        '    "": { "name": "demo" },',
        '    "node_modules/asn1": {',
        '      "version": "0.2.6"',
        '    }',
        '  }',
        '}',
      })
      local where = licenses.locate(root, item('pkg:npm/asn1@0.2.6'), {})
      assert.equals(root .. '/package-lock.json', where.filename)
      assert.equals(5, where.lnum)
      where = licenses.locate(root, item('pkg:npm/gone@1.0.0'), {})
      assert.equals(root .. '/package.json', where.filename)
      assert.equals(1, where.lnum)
      assert.is_nil(licenses.locate(root, item('pkg:gem/rails@7'), {}))
    end)
  end)

  describe('show', function()
    it('reports denied and reviewed packages, and fills quickfix', function()
      local root = dir .. '/proj'
      h.write(root .. '/package.json', {
        '{',
        '  "dependencies": {',
        '    "readline": "8.0.0"',
        '  }',
        '}',
      })
      licenses.show(CYCLONEDX, root, 'test')
      local lines =
        vim.api.nvim_buf_get_lines(vim.api.nvim_get_current_buf(), 0, -1, false)
      local text = table.concat(lines, '\n')
      assert.matches('4 packages: 1 denied, 1 to review, 2 allowed', text)
      assert.matches(
        'readline 8.0.0: GPL%-3.0%-only `pkg:npm/readline@8.0.0`',
        text
      )
      assert.matches('@scope/core 2.0.0: unknown', text)
      local items = vim.fn.getqflist()
      assert.equals(2, #items)
      assert.equals('W', items[1].type)
      assert.equals('E', items[2].type)
      assert.equals(
        root .. '/package.json',
        vim.api.nvim_buf_get_name(items[2].bufnr)
      )
      assert.equals(3, items[2].lnum)
      assert.equals(vim.log.levels.ERROR, noted('1 denied').level)
    end)

    it('never says all is allowed of an empty SBOM', function()
      licenses.show(
        { bomFormat = 'CycloneDX', components = {} },
        dir .. '/proj',
        'test'
      )
      assert.truthy(noted('lists no package'))
      for _, note in ipairs(notes) do
        assert.is_nil(note.msg:find('allowed'))
      end
    end)

    it('says all licenses are allowed only when every one is', function()
      licenses.show({
        bomFormat = 'CycloneDX',
        components = { CYCLONEDX.components[2] },
      }, dir .. '/proj', 'test')
      assert.truthy(noted('All 1 licenses allowed'))
    end)

    it('reports a malformed project file and keeps the defaults', function()
      h.write(dir .. '/proj/.nvim/licenses.json', { 'not json' })
      licenses.show(CYCLONEDX, dir .. '/proj', 'test')
      local note = noted('not a JSON object')
      assert.equals(vim.log.levels.ERROR, note.level)
      assert.truthy(noted('1 denied'))
    end)
  end)

  describe('scan', function()
    --- A `trivy` that keeps its arguments, prints `out` and exits `code`
    local function trivy(out, code)
      h.write(dir .. '/out.json', { out })
      h.write(dir .. '/bin/trivy', {
        '#!/bin/sh',
        'echo "$@" > "' .. dir .. '/args"',
        'cat "' .. dir .. '/out.json"',
        'exit ' .. (code or 0),
      })
      vim.fn.setfperm(dir .. '/bin/trivy', 'rwxr-xr-x')
    end

    it('reads the CycloneDX SBOM trivy lists', function()
      trivy(vim.json.encode(CYCLONEDX))
      licenses.scan(dir .. '/proj')
      assert.truthy(noted('1 denied, 1 to review, 2 allowed of 4'))
      assert.matches(
        'fs %-%-quiet %-%-format cyclonedx',
        vim.fn.readfile(dir .. '/args')[1]
      )
    end)

    it('says a failed run failed', function()
      trivy('boom', 1)
      licenses.scan(dir .. '/proj')
      assert.equals(
        vim.log.levels.ERROR,
        noted('trivy could not list the packages').level
      )
    end)

    it('has Mason install trivy when it is missing', function()
      licenses.scan(dir .. '/proj')
      assert.is_true(vim.wait(3000, function() return installed ~= nil end))
      assert.equals('trivy', installed)
    end)
  end)

  it('reads an SPDX file given to the command', function()
    h.write(dir .. '/sbom.spdx.json', { vim.json.encode(SPDX) })
    licenses.from_file(dir .. '/sbom.spdx.json', dir .. '/proj')
    assert.truthy(noted('0 denied, 1 to review, 1 allowed of 2'))
  end)
end)
