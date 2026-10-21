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
        dir = dir .. '/packages/ls',
      },
      {
        name = 'ansible-lint',
        version = '26.9.0',
        purl = 'pkg:pypi/ansible-lint@26.9.0',
        source = 'mason',
        dir = dir .. '/packages/ansible-lint',
      },
      {
        name = 'mine',
        version = 'unknown',
        source = 'mason',
        dir = dir .. '/packages/mine',
      },
    }, components)
  end)

  it('lists what lazy.nvim and Mason installed, sorted by name', function()
    local Config = require('lazy.core.config')
    h.write(dir .. '/lazy-lock.json', {
      vim.json.encode({
        ['b.nvim'] = { branch = 'main', commit = 'bbb' },
        ['a.nvim'] = { branch = 'main', commit = 'aaa' },
      }),
    })
    h.write(dir .. '/mason/packages/a.nvim/mason-receipt.json', {
      vim.json.encode({
        name = 'a.nvim',
        source = { id = 'pkg:npm/a.nvim@1.0.0' },
      }),
    })
    local restores = {
      h.stub(Config, 'options', { lockfile = dir .. '/lazy-lock.json' }),
      h.stub(Config, 'plugins', {
        ['a.nvim'] = { url = 'https://github.com/o/a.nvim' },
        ['b.nvim'] = { url = 'https://github.com/o/b.nvim' },
      }),
      h.stub(
        package.loaded,
        'mason.settings',
        { current = { install_root_dir = dir .. '/mason' } }
      ),
    }
    local ok, components = pcall(sbom.components)
    for _, restore in ipairs(restores) do
      restore()
    end
    assert(ok, components)
    assert.same(
      { 'a.nvim lazy.nvim', 'a.nvim mason', 'b.nvim lazy.nvim' },
      vim.tbl_map(function(c) return c.name .. ' ' .. c.source end, components)
    )
    assert.equals('pkg:github/o/a.nvim@aaa', components[1].purl)
  end)

  describe('licenses', function()
    local MIT = {
      'MIT License',
      '',
      'Copyright (c) 2024 Someone',
      '',
      'Permission is hereby granted, free of charge, to any person obtaining',
      'a copy of this software ...',
    }

    it('names the license of a text by what it says', function()
      local cases = {
        ['MIT'] = table.concat(MIT, '\n'),
        ['Apache-2.0'] = 'Apache License\n Version 2.0, January 2004',
        ['GPL-3.0'] = 'GNU GENERAL PUBLIC LICENSE\n  Version 3, 29 June 2007',
        ['GPL-2.0'] = 'GNU GENERAL PUBLIC LICENSE\n  Version 2, June 1991',
        ['AGPL-3.0'] = 'GNU AFFERO GENERAL PUBLIC LICENSE\nVersion 3',
        ['LGPL-2.1'] = 'GNU LESSER GENERAL PUBLIC LICENSE\nVersion 2.1',
        ['MPL-2.0'] = 'Mozilla Public License Version 2.0',
        ['LGPL-2.0'] = 'GNU LIBRARY GENERAL PUBLIC LICENSE\nVersion 2, June'
          .. ' 1991 ... the ordinary GNU General Public License',
        ['BSD-3-Clause'] = 'Redistribution and use in source and binary forms,'
          .. ' with or without\nmodification ... Neither the name of',
        ['BSD-2-Clause'] = 'Redistribution and use in source and binary'
          .. ' forms, with or without modification',
        ['ISC'] = 'Permission to use, copy, modify, and/or distribute this'
          .. ' software for any purpose with or without fee is hereby'
          .. ' granted, provided that the above copyright notice',
        ['0BSD'] = 'Permission to use, copy, modify, and/or distribute this'
          .. ' software for any purpose with or without fee is hereby'
          .. ' granted.',
        ['Unlicense'] = 'This is free and unencumbered software released'
          .. ' into the public domain.',
        ['Apache-2.0 OR MIT'] = '// SPDX-License-Identifier: Apache-2.0 OR MIT',
        ['Vim'] = 'You may redistribute this package under the same terms as'
          .. '\nVim itself.',
      }
      for spdx, text in pairs(cases) do
        assert.equals(spdx, sbom.detect_license(text), spdx)
      end
      assert.is_nil(sbom.detect_license('All rights reserved.'))
    end)

    it('names a license by its title before the others it names', function()
      local cases = {
        ['MPL-2.0'] = {
          'Mozilla Public License Version 2.0',
          '==================================',
          '',
          '1. Definitions',
          '1.12. "Secondary License"',
          '    means either the GNU General Public License, Version 2.0, the',
          '    GNU Lesser General Public License, Version 2.1, the GNU Affero',
          '    General Public License, Version 3.0, or any later versions of',
          '    those licenses.',
        },
        ['EPL-2.0'] = {
          'Eclipse Public License - v 2.0',
          '',
          '    THE ACCOMPANYING PROGRAM IS PROVIDED UNDER THE TERMS OF THIS',
          '    ECLIPSE PUBLIC LICENSE ("AGREEMENT").',
          '"Secondary License" means either the GNU General Public License,',
          'Version 2.0, or any later versions of that license.',
        },
        ['GPL-2.0'] = {
          '                    GNU GENERAL PUBLIC LICENSE',
          '                       Version 2, June 1991',
          '',
          ' Copyright (C) 1989, 1991 Free Software Foundation, Inc.,',
          '(Some other Free Software Foundation software is covered by',
          'the GNU Library General Public License instead.)',
        },
      }
      for spdx, lines in pairs(cases) do
        assert.equals(
          spdx,
          sbom.detect_license(table.concat(lines, '\n')),
          spdx
        )
      end
    end)

    it('reads the license file of a directory', function()
      h.write(dir .. '/a/LICENSE', MIT)
      h.write(
        dir .. '/b/COPYING.md',
        { 'GNU GENERAL PUBLIC LICENSE', 'Version 3' }
      )
      vim.fn.mkdir(dir .. '/c', 'p')
      assert.equals('MIT', sbom.license_of_dir(dir .. '/a'))
      assert.equals('GPL-3.0', sbom.license_of_dir(dir .. '/b'))
      assert.is_nil(sbom.license_of_dir(dir .. '/c'))
      assert.is_nil(sbom.license_of_dir(dir .. '/missing'))
    end)

    it('matches a policy entry, a trailing star any version', function()
      assert.is_true(sbom.license_matches('AGPL-3.0', { 'AGPL-*' }))
      assert.is_true(sbom.license_matches('MIT OR AGPL-3.0', { 'AGPL-*' }))
      assert.is_false(sbom.license_matches('LGPL-3.0', { 'GPL-*' }))
      assert.is_true(sbom.license_matches('SSPL-1.0', { 'SSPL-1.0' }))
      assert.is_false(sbom.license_matches('MIT', {}))
    end)

    it('reports denied, flagged and unknown licenses first', function()
      local lines, counts = sbom.license_report({
        { name = 'a', version = '1', source = 'mason', license = 'MIT' },
        {
          name = 'b',
          version = '1',
          source = 'lazy.nvim',
          license = 'AGPL-3.0',
        },
        { name = 'c', version = '1', source = 'lazy.nvim' },
        { name = 'd', version = '1', source = 'mason', license = 'BUSL-1.1' },
      }, { deny = { 'BUSL-*' }, review = { 'AGPL-*' } })
      assert.same({ deny = 1, review = 1, unknown = 1, total = 4 }, counts)
      local text = table.concat(lines, '\n')
      assert.is_truthy(
        text:find('## Denied\n\n- d 1 (mason): BUSL-1.1', 1, true)
      )
      assert.is_truthy(
        text:find('## To review\n\n- b 1 (lazy.nvim): AGPL-3.0', 1, true)
      )
      assert.is_truthy(text:find('## Unknown\n\n- c 1 (lazy.nvim)', 1, true))
      assert.is_truthy(text:find('| MIT | 1 |', 1, true))
    end)

    it(
      'lists the license of each component in the CycloneDX document',
      function()
        local bom = sbom.bom({
          { name = 'x', version = '1', source = 'mason', license = 'MIT' },
          {
            name = 'y',
            version = '1',
            source = 'mason',
            license = 'MIT OR Apache-2.0',
          },
          { name = 'z', version = '1', source = 'mason' },
        }, 0)
        assert.same(
          { { license = { id = 'MIT' } } },
          bom.components[1].licenses
        )
        assert.same(
          { { expression = 'MIT OR Apache-2.0' } },
          bom.components[2].licenses
        )
        assert.is_nil(bom.components[3].licenses)
      end
    )

    it('reads the licenses of what lazy.nvim and Mason installed', function()
      h.write(dir .. '/plugins/a.nvim/LICENSE', MIT)
      local components = sbom.with_licenses({
        {
          name = 'a.nvim',
          version = 'x',
          source = 'lazy.nvim',
          dir = dir .. '/plugins/a.nvim',
        },
        {
          name = 'tool',
          version = '1',
          source = 'mason',
          dir = dir .. '/none',
        },
      }, function(name)
        if name == 'tool' then return { 'Apache-2.0' } end
      end)
      assert.equals('MIT', components[1].license)
      assert.equals('Apache-2.0', components[2].license)
    end)
  end)

  it('reads a lockfile from disk when no lines are given', function()
    h.write(dir .. '/go.mod', { 'require x.org/y v1.0.0' })
    assert.equals(1, #sbom.lockfile(dir .. '/go.mod'))
    assert.same({}, sbom.lockfile(dir .. '/missing/go.mod'))
    assert.is_nil(sbom.lockfile(dir .. '/notes.txt'))
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

    it('asks OSV about what is installed, and shows what it knows', function()
      local restore = h.stub(
        sbom,
        'components',
        function()
          return {
            {
              name = 'x',
              version = '1',
              purl = 'pkg:npm/x@1',
              source = 'mason',
            },
          }
        end
      )
      h.write(dir .. '/response.1', {
        vim.json.encode({ results = { { vulns = { { id = 'GHSA-x' } } } } }),
      })
      h.write(dir .. '/response.2', { vim.json.encode({ results = { {} } }) })
      h.write(dir .. '/response.3', { 'garbage' })
      sbom.command({ fargs = { 'osv' } })
      assert.is_true(
        vim.wait(10000, function() return vim.bo.filetype == 'markdown' end, 20)
      )
      assert.equals('Asking OSV about 1 plugins and packages…', notes[1])
      assert.equals(
        '# Known vulnerabilities: 1',
        vim.api.nvim_buf_get_lines(0, 0, 1, false)[1]
      )
      sbom.osv()
      assert.is_true(vim.wait(10000, function() return #notes >= 3 end, 20))
      assert.equals(
        'No known vulnerabilities in the 1 plugins and packages asked',
        notes[3]
      )
      sbom.osv()
      assert.is_true(vim.wait(10000, function() return #notes >= 5 end, 20))
      restore()
      assert.equals('OSV answered with something that is not JSON', notes[5])
    end)

    it('says what it needs before asking OSV', function()
      local restore = h.stub(sbom, 'components', function() return {} end)
      sbom.osv()
      restore()
      restore = h.stub(
        sbom,
        'components',
        function()
          return {
            {
              name = 'x',
              version = '1',
              purl = 'pkg:npm/x@1',
              source = 'mason',
            },
          }
        end
      )
      h.write(dir .. '/go.mod', { 'require x.org/y v1.0.0' })
      local restore_exe = h.stub(vim.fn, 'executable', function() return 0 end)
      sbom.osv()
      sbom.ask_lockfiles({ dir .. '/go.mod' })
      restore_exe()
      restore()
      sbom.ask_lockfiles(nil, 'boom')
      h.write(dir .. '/empty/go.mod', { 'module x' })
      sbom.ask_lockfiles({ dir .. '/empty/go.mod' })
      assert.same({
        'Nothing to ask OSV about',
        'curl is not installed',
        'curl is not installed',
        'Could not list the lockfiles: boom',
        'No package in 1 lockfiles',
      }, notes)
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
