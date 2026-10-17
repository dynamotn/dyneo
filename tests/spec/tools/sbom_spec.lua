local h = require('helpers')

describe('tools.sbom', function()
  local sbom, dir, cleanup

  before_each(function()
    dir, cleanup = h.tmpdir()
    h.unload('tools.sbom')
    sbom = require('tools.sbom')
  end)
  after_each(function()
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  describe('plugin_purl', function()
    it('names a repository of a forge by its own purl type', function()
      assert.equals(
        'pkg:github/folke/snacks.nvim@abc123',
        sbom.plugin_purl(
          'snacks.nvim',
          'https://github.com/folke/snacks.nvim.git',
          'abc123'
        )
      )
      assert.equals(
        'pkg:gitlab/group/sub/repo@abc123',
        sbom.plugin_purl('repo', 'git@gitlab.com:Group/Sub/Repo.git', 'abc123')
      )
    end)

    it('falls back to a generic purl with the clone URL', function()
      assert.equals(
        'pkg:generic/ci.nvim@abc123?vcs_url='
          .. 'git%2Bhttps%3A%2F%2Fforge.example.org%2Fme%2Fci.nvim%40abc123',
        sbom.plugin_purl(
          'ci.nvim',
          'https://forge.example.org/me/ci.nvim',
          'abc123'
        )
      )
      assert.equals(
        'pkg:generic/local.nvim@abc123',
        sbom.plugin_purl('local.nvim', nil, 'abc123')
      )
    end)
  end)

  it('lists the plugins of a lockfile', function()
    local lockfile = dir .. '/lazy-lock.json'
    h.write(lockfile, {
      vim.json.encode({
        ['snacks.nvim'] = { branch = 'main', commit = 'aaa111' },
        ['broken'] = 'not a table',
      }),
    })
    assert.same(
      {
        {
          name = 'snacks.nvim',
          version = 'aaa111',
          purl = 'pkg:github/folke/snacks.nvim@aaa111',
          source = 'lazy.nvim',
        },
      },
      sbom.plugins(lockfile, {
        ['snacks.nvim'] = 'https://github.com/folke/snacks.nvim',
      })
    )
  end)

  it('lists the packages of the Mason receipts', function()
    h.write(dir .. '/packages/ansible-lint/mason-receipt.json', {
      vim.json.encode({
        name = 'ansible-lint',
        source = { id = 'pkg:pypi/ansible-lint@26.9.0' },
      }),
    })
    h.write(dir .. '/packages/ls/mason-receipt.json', {
      vim.json.encode({
        name = '@ansible/ls',
        source = { id = 'pkg:npm/%40ansible/ls@1.2.3?x=y' },
      }),
    })
    h.write(dir .. '/packages/mine/mason-receipt.json', {
      vim.json.encode({ name = 'mine', source = { id = 'dytoy:mine' } }),
    })
    vim.fn.mkdir(dir .. '/packages/no-receipt', 'p')

    local components = sbom.mason(dir)
    table.sort(components, function(a, b) return a.name < b.name end)
    assert.same({
      {
        name = '@ansible/ls',
        version = '1.2.3',
        purl = 'pkg:npm/%40ansible/ls@1.2.3?x=y',
        source = 'mason',
      },
      {
        name = 'ansible-lint',
        version = '26.9.0',
        purl = 'pkg:pypi/ansible-lint@26.9.0',
        source = 'mason',
      },
      { name = 'mine', version = 'unknown', source = 'mason' },
    }, components)
  end)

  it('writes a CycloneDX document', function()
    local bom = sbom.bom({
      {
        name = 'x',
        version = '1',
        purl = 'pkg:npm/x@1',
        source = 'mason',
      },
      { name = 'mine', version = 'unknown', source = 'mason' },
    }, 0)
    assert.equals('CycloneDX', bom.bomFormat)
    assert.equals('1.5', bom.specVersion)
    assert.is_truthy(
      bom.serialNumber:match(
        '^urn:uuid:%x%x%x%x%x%x%x%x%-%x%x%x%x%-4%x%x%x%-[89ab]%x%x%x%-%x+$'
      )
    )
    assert.equals('1970-01-01T00:00:00Z', bom.metadata.timestamp)
    assert.equals('pkg:npm/x@1', bom.components[1]['bom-ref'])
    assert.equals('mason:mine', bom.components[2]['bom-ref'])
    assert.same(
      { { name = 'dyneo:installed-by', value = 'mason' } },
      bom.components[1].properties
    )
  end)

  describe('osv', function()
    local components = {
      { name = 'a', version = '1', purl = 'pkg:npm/a@1', source = 'mason' },
      {
        name = 'b',
        version = 'v2',
        purl = 'pkg:github/o/b@v2',
        source = 'mason',
      },
      {
        name = 'c.nvim',
        version = 'abc123',
        purl = 'pkg:github/o/c.nvim@abc123',
        source = 'lazy.nvim',
      },
      { name = 'mine', version = 'unknown', source = 'mason' },
    }

    it('asks by purl for a package and by commit for a plugin', function()
      local queries, asked = sbom.osv_queries(components)
      assert.same({
        { package = { purl = 'pkg:npm/a@1' } },
        { commit = 'abc123' },
      }, queries)
      assert.same(
        { 'a', 'c.nvim' },
        vim.tbl_map(function(c) return c.name end, asked)
      )
    end)

    it('reports the components OSV knows a vulnerability of', function()
      local _, asked = sbom.osv_queries(components)
      local findings = sbom.osv_findings(asked, {
        results = {
          { vulns = { { id = 'GHSA-2' }, { id = 'CVE-1' } } },
          {},
        },
      })
      assert.equals(1, #findings)
      assert.equals('a', findings[1].component.name)
      assert.same({ 'CVE-1', 'GHSA-2' }, findings[1].ids)

      ---@cast findings -nil
      local lines = sbom.osv_report(findings, #asked, #components)
      assert.equals('# Known vulnerabilities: 1', lines[1])
      assert.is_truthy(vim.tbl_contains(lines, '## a 1 (mason)'))
      assert.is_truthy(
        vim.tbl_contains(lines, '- CVE-1 https://osv.dev/vulnerability/CVE-1')
      )
    end)
  end)

  describe('an answer short of results', function()
    it('is an error, not a clean report', function()
      local asked = {
        { name = 'a', version = '1', source = 'mason' },
        { name = 'b', version = '2', source = 'mason' },
      }
      for _, response in ipairs({
        {},
        { results = vim.NIL },
        { results = { { vulns = {} } } },
      }) do
        local findings, err = sbom.osv_findings(asked, response)
        assert.is_nil(findings)
        assert.is_truthy(err:find('for 2 questions', 1, true))
      end
    end)
  end)

  describe('lockfiles', function()
    it('reads go.mod, the require block and single lines', function()
      local components = sbom.lockfile('/p/go.mod', {
        'module example.com/me',
        '',
        'require github.com/single/one v1.0.0',
        'require (',
        '\tgolang.org/x/net v0.17.0 // indirect',
        '\tgithub.com/Foo/bar v2.0.0+incompatible',
        ')',
        'replace (',
        '\tgithub.com/x/y v1.0.0 => ../y',
        ')',
      })
      assert.same({
        'pkg:golang/github.com/single/one@v1.0.0',
        'pkg:golang/golang.org/x/net@v0.17.0',
        'pkg:golang/github.com/Foo/bar@v2.0.0%2Bincompatible',
      }, vim.tbl_map(function(c) return c.purl end, components))
      assert.same(
        { 3, 5, 6 },
        vim.tbl_map(function(c) return c.line end, components)
      )
      assert.equals('lockfile', components[1].source)
      assert.equals('/p/go.mod', components[1].file)
    end)

    it('reads Cargo.lock, leaving the workspace crates out', function()
      local components = sbom.lockfile('/p/Cargo.lock', {
        'version = 3',
        '',
        '[[package]]',
        'name = "mine"',
        'version = "0.1.0"',
        '',
        '[[package]]',
        'name = "serde"',
        'version = "1.0.190"',
        'source = "registry+https://github.com/rust-lang/crates.io-index"',
        'checksum = "abc"',
      })
      assert.equals(1, #components)
      assert.equals('pkg:cargo/serde@1.0.190', components[1].purl)
      assert.equals(8, components[1].line)
    end)

    it('reads uv.lock and poetry.lock, names as PyPI compares them', function()
      local uv = sbom.lockfile('/p/uv.lock', {
        '[[package]]',
        'name = "my-app"',
        'version = "0.1.0"',
        'source = { editable = "." }',
        '',
        '[[package]]',
        'name = "Typing_Extensions"',
        'version = "4.8.0"',
        'source = { registry = "https://pypi.org/simple" }',
        '',
        '[package.optional-dependencies]',
        'name = "not-a-package"',
      })
      assert.same(
        { 'pkg:pypi/typing-extensions@4.8.0' },
        vim.tbl_map(function(c) return c.purl end, uv)
      )
      assert.equals(7, uv[1].line)

      local poetry = sbom.lockfile('/p/poetry.lock', {
        '[[package]]',
        'name = "requests"',
        'version = "2.31.0"',
        'description = "HTTP"',
        '',
        '[package.dependencies]',
        'idna = ">=2.5"',
      })
      assert.same(
        { 'pkg:pypi/requests@2.31.0' },
        vim.tbl_map(function(c) return c.purl end, poetry)
      )
    end)

    it('reads package-lock.json, each package at its key', function()
      local lines = vim.split(
        [[{
  "name": "app",
  "lockfileVersion": 3,
  "packages": {
    "": { "name": "app", "version": "1.0.0" },
    "node_modules/lodash": {
      "version": "4.17.20"
    },
    "node_modules/@babel/core": {
      "version": "7.0.0"
    },
    "node_modules/a/node_modules/lodash": {
      "version": "3.0.0"
    },
    "node_modules/linked": {
      "resolved": "../linked",
      "link": true
    }
  }
}]],
        '\n'
      )
      local components = sbom.lockfile('/p/package-lock.json', lines)
      assert.same({
        { 'pkg:npm/lodash@4.17.20', 6 },
        { 'pkg:npm/%40babel/core@7.0.0', 9 },
        { 'pkg:npm/lodash@3.0.0', 12 },
      }, vim.tbl_map(
        function(c) return { c.purl, c.line } end,
        components
      ))
      assert.same({}, sbom.lockfile('/p/package-lock.json', { 'not json' }))
    end)

    it(
      'knows only the lockfiles it can read',
      function() assert.is_nil(sbom.lockfile('/p/yarn.lock', {})) end
    )

    it('finds the lockfiles git tracks, at any depth', function()
      h.write(dir .. '/go.mod', { 'module x' })
      h.write(dir .. '/web/package-lock.json', { '{}' })
      h.write(dir .. '/node_modules/x/package-lock.json', { '{}' })
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
      vim.system({ 'git', 'add', 'go.mod', 'web' }, { cwd = dir }):wait()
      local files
      sbom.find_lockfiles(dir, function(found) files = found end)
      -- git runs off the main loop
      assert.is_nil(files)
      assert.is_true(vim.wait(5000, function() return files ~= nil end, 10))
      table.sort(files)
      assert.same({ dir .. '/go.mod', dir .. '/web/package-lock.json' }, files)
    end)

    it('looks at the top when git tracks no lockfile yet', function()
      h.write(dir .. '/go.mod', { 'module x' })
      h.write(dir .. '/main.go', { 'package main' })
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
      vim.system({ 'git', 'add', 'main.go' }, { cwd = dir }):wait()
      local files
      sbom.find_lockfiles(dir, function(found) files = found end)
      assert.is_true(vim.wait(5000, function() return files ~= nil end, 10))
      assert.same({ dir .. '/go.mod' }, files)
    end)

    it('lists nothing when git printed more than can be read', function()
      local restore = h.stub(require('util.system'), 'MAX_BYTES', 4)
      h.write(dir .. '/go.mod', { 'module x' })
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
      vim.system({ 'git', 'add', 'go.mod' }, { cwd = dir }):wait()
      local done, files, err
      sbom.find_lockfiles(dir, function(found, why)
        done, files, err = true, found, why
      end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      restore()
      assert.is_nil(files)
      assert.truthy(err:find('more than can be read', 1, true))
    end)

    it('looks at the top only outside git', function()
      h.write(dir .. '/Cargo.lock', {})
      h.write(dir .. '/sub/go.mod', {})
      -- Not a git repository: git ls-files fails
      local files
      sbom.find_lockfiles(dir, function(found) files = found end)
      assert.is_true(vim.wait(5000, function() return files ~= nil end, 10))
      assert.same({ dir .. '/Cargo.lock' }, files)
    end)
  end)

  describe('lock', function()
    local path, notes, restore_notify

    before_each(function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      -- A curl that keeps each request and answers with the next response
      h.write(dir .. '/bin/curl', {
        '#!/bin/sh',
        'n=$(cat "' .. dir .. '/count" 2>/dev/null || echo 0)',
        'n=$((n + 1))',
        'echo "$n" > "' .. dir .. '/count"',
        'cat > "' .. dir .. '/request.$n"',
        'cat "' .. dir .. '/response.$n"',
      })
      vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
      path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      notes = {}
      restore_notify = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
    end)
    after_each(function()
      vim.env.PATH = path
      restore_notify()
      vim.diagnostic.reset()
    end)

    it('asks in batches, and puts findings on their lines', function()
      sbom.OSV_BATCH = 2
      h.write(dir .. '/Cargo.lock', {
        '[[package]]',
        'name = "a"',
        'version = "1.0.0"',
        'source = "registry"',
        '[[package]]',
        'name = "b"',
        'version = "1.0.0"',
        'source = "registry"',
        '[[package]]',
        'name = "c"',
        'version = "1.0.0"',
        'source = "registry"',
      })
      h.write(dir .. '/response.1', {
        vim.json.encode({
          results = { {}, { vulns = { { id = 'RUSTSEC-1' } } } },
        }),
      })
      h.write(dir .. '/response.2', {
        vim.json.encode({ results = { { vulns = { { id = 'GHSA-c' } } } } }),
      })
      vim.cmd.edit(dir .. '/Cargo.lock')
      local bufnr = vim.api.nvim_get_current_buf()
      sbom.command({ fargs = { 'lock' } })
      assert.is_true(vim.wait(10000, function() return #notes >= 2 end, 20))
      assert.equals('2 of 3 packages with known vulnerabilities', notes[2])

      local first = vim.json.decode(
        table.concat(vim.fn.readfile(dir .. '/request.1'), '\n')
      )
      assert.equals(2, #first.queries)
      assert.equals('pkg:cargo/a@1.0.0', first.queries[1].package.purl)

      local messages = vim.tbl_map(
        function(d) return d.lnum .. ' ' .. d.message end,
        vim.diagnostic.get(bufnr)
      )
      table.sort(messages)
      assert.same({ '5 b 1.0.0: RUSTSEC-1', '9 c 1.0.0: GHSA-c' }, messages)
      assert.equals(2, #vim.fn.getqflist())
    end)

    it('stops at a failed batch', function()
      h.write(dir .. '/bin/curl', { '#!/bin/sh', 'echo boom >&2', 'exit 22' })
      h.write(dir .. '/go.mod', { 'require x.org/y v1.0.0' })
      vim.cmd.edit(dir .. '/go.mod')
      sbom.lock()
      assert.is_true(vim.wait(10000, function() return #notes >= 2 end, 20))
      assert.equals('OSV query failed: boom', notes[2])
    end)

    it('says when there is no lockfile', function()
      vim.cmd.edit(dir .. '/README.md')
      sbom.lock()
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
      assert.is_truthy(notes[1]:find('^No lockfile found'))
    end)
  end)

  it('writes the document to a path, or shows it', function()
    local restore = h.stub(
      sbom,
      'components',
      function()
        return {
          { name = 'x', version = '1', purl = 'pkg:npm/x@1', source = 'mason' },
        }
      end
    )
    local notes = {}
    local restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )

    -- The stubs go back whatever fails, so a failure here stays here
    local ok, err = pcall(function()
      sbom.command({ fargs = { dir .. '/out/sbom.cdx.json' } })
      local written = vim.json.decode(
        table.concat(vim.fn.readfile(dir .. '/out/sbom.cdx.json'), '\n')
      )
      assert.equals('pkg:npm/x@1', written.components[1].purl)
      assert.is_truthy(
        notes[1]:find('1 plugins and packages written to', 1, true)
      )

      -- Asked before the file is written over, and left as it was on no
      h.write(dir .. '/out/sbom.cdx.json', { 'mine' })
      local restore_confirm = h.stub(vim.fn, 'confirm', function() return 2 end)
      sbom.command({ fargs = { dir .. '/out/sbom.cdx.json' } })
      restore_confirm()
      assert.same({ 'mine' }, vim.fn.readfile(dir .. '/out/sbom.cdx.json'))
      assert.equals('Not written', notes[#notes])

      sbom.command({ fargs = {} })
      assert.equals('json', vim.bo.filetype)
    end)
    restore_notify()
    restore()
    if not ok then error(err, 0) end
  end)
end)
