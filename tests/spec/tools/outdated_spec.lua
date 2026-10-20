local h = require('helpers')

local DAY = 86400
-- A fixed now: 2026-10-20T00:00:00Z
local NOW = 1792454400

--- `seconds` before `NOW` as the registries write a time
local function ago(seconds) return os.date('!%Y-%m-%dT%H:%M:%SZ', NOW - seconds) end

describe('tools.outdated', function()
  local outdated, restore_window

  before_each(function()
    h.unload(
      'tools.outdated',
      'tools.lazy-quarantine',
      'tools.mason-quarantine'
    )
    outdated = require('tools.outdated')
    restore_window = h.stub(_G, 'DyNeo', { quarantine_window = 7 * DAY })
  end)
  after_each(function() restore_window() end)

  describe('manifests', function()
    --- `outdated.deps`, each version checked to be where its `col` says
    local function read(reader, lines)
      local deps = outdated.deps(reader, lines)
      for _, dep in ipairs(deps) do
        assert.are.equal(
          dep.version,
          lines[dep.line]:sub(dep.col, dep.col + #dep.version - 1),
          dep.name
        )
      end
      return deps
    end

    it('names the reader of each manifest by its path', function()
      assert.are.equal('npm', outdated.manifest('/p/package.json'))
      assert.are.equal('go', outdated.manifest('/p/go.mod'))
      assert.are.equal('pypi', outdated.manifest('/p/requirements-dev.txt'))
      assert.are.equal('pyproject', outdated.manifest('/p/pyproject.toml'))
      assert.are.equal('terraform', outdated.manifest('/p/versions.tf'))
      assert.are.equal(
        'actions',
        outdated.manifest('/p/.github/workflows/ci.yml')
      )
      assert.are.equal('actions', outdated.manifest('/p/x/action.yaml'))
      assert.is_nil(outdated.manifest('/p/package-lock.json'))
      assert.is_nil(outdated.manifest('/p/workflows/ci.yml'))
    end)

    it('reads the registry ranges of package.json, nothing else', function()
      local deps = read('npm', {
        '{',
        '  "name": "app",',
        '  "version": "1.0.0",',
        '  "dependencies": {',
        '    "left-pad": "^1.1.0",',
        '    "@scope/lib": "~2.0.1",',
        '    "local": "file:../local",',
        '    "git": "github:o/r",',
        '    "any": "*"',
        '  },',
        '  "devDependencies": { "x": ">=3.1 <4" }',
        '}',
      })
      assert.are.same(
        {
          { line = 5, name = 'left-pad', version = '1.1.0', col = 19 },
          { line = 6, name = '@scope/lib', version = '2.0.1', col = 21 },
        },
        vim.tbl_map(
          function(dep)
            return {
              line = dep.line,
              name = dep.name,
              version = dep.version,
              col = dep.col,
            }
          end,
          vim.list_slice(deps, 1, 2)
        )
      )
      assert.are.equal(3, #deps)
      assert.are.equal('x', deps[3].name)
      assert.are.equal('3.1', deps[3].version)
      assert.are.equal('npm', deps[1].kind)
    end)

    it('reads go.mod, pseudo-versions left out', function()
      local deps = read('go', {
        'module example.com/app',
        '',
        'require golang.org/x/text v0.20.0',
        'require (',
        '\tgithub.com/BurntSushi/toml v1.3.2 // indirect',
        '\tgithub.com/o/r v0.0.0-20240101120000-abcdef123456',
        ')',
      })
      assert.are.equal(2, #deps)
      assert.are.equal('golang.org/x/text', deps[1].name)
      assert.are.equal('v0.20.0', deps[1].version)
      assert.are.equal(3, deps[1].line)
      assert.are.equal('github.com/BurntSushi/toml', deps[2].name)
      assert.are.equal(5, deps[2].line)
    end)

    it('reads requirements, options, URLs and bare names left out', function()
      local deps = read('pypi', {
        '# pinned',
        '-r base.txt',
        'Requests[socks]==2.31.0  # http',
        'django>=4.2,<5',
        'flask',
        'pkg @ https://example.com/pkg.whl',
      })
      assert.are.equal(2, #deps)
      assert.are.equal('requests', deps[1].name)
      assert.are.equal('2.31.0', deps[1].version)
      assert.are.equal(18, deps[1].col)
      assert.are.equal('django', deps[2].name)
      assert.are.equal('4.2', deps[2].version)
    end)

    it(
      'reads the dependencies of pyproject.toml, PEP 621 and Poetry',
      function()
        local deps = read('pyproject', {
          '[project]',
          'name = "app"',
          'version = "1.0"',
          'dependencies = [',
          '  "httpx[http2]>=0.27",',
          '  "rich==13.7.1",',
          ']',
          '[project.optional-dependencies]',
          'dev = ["pytest>=8.0"]',
          '[tool.poetry.dependencies]',
          'python = "^3.12"',
          'pydantic = "^2.6"',
          'boto3 = { version = "1.34.0", optional = true }',
        })
        assert.are.same(
          { 'httpx', 'rich', 'pytest', 'pydantic', 'boto3' },
          vim.tbl_map(function(dep) return dep.name end, deps)
        )
        assert.are.same(
          { '0.27', '13.7.1', '8.0', '2.6', '1.34.0' },
          vim.tbl_map(function(dep) return dep.version end, deps)
        )
        assert.are.equal(5, deps[1].line)
      end
    )

    it('reads providers and registry modules of Terraform', function()
      local deps = read('terraform', {
        'terraform {',
        '  required_providers {',
        '    aws = {',
        '      source  = "hashicorp/aws"',
        '      version = "~> 5.0" # pinned',
        '    }',
        '    random = { source = "registry.terraform.io/hashicorp/random", version = ">= 3.5.1" }',
        '    other = { source = "example.com/o/other", version = "1.0.0" }',
        '  }',
        '}',
        '',
        'module "vpc" {',
        '  source  = "terraform-aws-modules/vpc/aws"',
        '  version = "5.1.0"',
        '}',
        'module "local" {',
        '  source = "./modules/local"',
        '}',
        'module "eks" {',
        '  source  = "terraform-aws-modules/eks/aws"',
        '  version = "~> 20.0"',
        '  cluster_version = "1.29"',
        '  node_groups = {',
        '    a = { version = "9.9" }',
        '  }',
        '}',
      })
      assert.are.same(
        {
          { 'tf-provider', 'hashicorp/aws', '5.0', 5 },
          { 'tf-provider', 'hashicorp/random', '3.5.1', 7 },
          { 'tf-module', 'terraform-aws-modules/vpc/aws', '5.1.0', 14 },
          { 'tf-module', 'terraform-aws-modules/eks/aws', '20.0', 21 },
        },
        vim.tbl_map(
          function(dep) return { dep.kind, dep.name, dep.version, dep.line } end,
          deps
        )
      )
    end)

    it(
      'reads the actions of a workflow, a pinned one by its comment',
      function()
        local sha = ('a'):rep(40)
        local deps = read('actions', {
          'steps:',
          '  - uses: actions/checkout@v4',
          '  - uses: actions/cache/save@' .. sha .. ' # v4.1.2',
          '  - uses: ./local-action',
          '  - uses: docker://alpine:3',
          '  - uses: o/r@main',
        })
        assert.are.equal(2, #deps)
        assert.are.equal('actions/checkout', deps[1].name)
        assert.are.equal('v4', deps[1].version)
        assert.is_falsy(deps[1].pinned)
        assert.are.equal('actions/cache', deps[2].name)
        assert.are.equal('v4.1.2', deps[2].version)
        assert.is_true(deps[2].pinned)
      end
    )
  end)

  describe('versions', function()
    it('compares release numbers, not strings', function()
      assert.is_true(outdated.compare('1.10.0', '1.9.9') > 0)
      assert.is_true(outdated.compare('v2', 'v1.99') > 0)
      assert.are.equal(0, outdated.compare('5.0', '5.0.0'))
      assert.is_true(outdated.compare('0.27.0', '0.28') < 0)
    end)

    it('tells prereleases apart, of semver and of PEP 440', function()
      for _, version in ipairs({
        '1.0.0-beta.1',
        'v2.0.0-rc1',
        '1.0a1',
        '2.0rc1',
        '1.0.dev3',
        '3.0.0b2',
      }) do
        assert.is_true(outdated.is_prerelease(version), version)
      end
      for _, version in ipairs({ '1.0.0', 'v4', '2.0.post1', '1.0.0+build' }) do
        assert.is_false(outdated.is_prerelease(version), version)
      end
    end)

    it('writes a release as precise as the version it replaces', function()
      assert.are.equal('5.31', outdated.format('5.31.0', '5.0'))
      assert.are.equal('v5', outdated.format('v5.0.1', 'v4'))
      assert.are.equal('v5', outdated.format('5.0.1', 'v4'))
      assert.are.equal('1.2.3', outdated.format('v1.2.3', '1.1.0'))
      assert.are.equal(
        'v2.1.0+incompatible',
        outdated.format('v2.1.0+incompatible', 'v2.0.0+incompatible')
      )
    end)

    it(
      'offers the newest release out of quarantine, and names a newer one held',
      function()
        local aged, held = outdated.pick('1.0.0', {
          { version = '1.1.0', time = NOW - 30 * DAY },
          { version = '1.2.0', time = NOW - 8 * DAY },
          { version = '1.3.0', time = NOW - 2 * DAY },
          { version = '1.4.0-beta.1', time = NOW - 20 * DAY },
          { version = '0.9.0', time = NOW - 90 * DAY },
        }, NOW)
        assert.are.equal('1.2.0', aged.version)
        assert.are.equal('1.3.0', held.version)
      end
    )

    it('never offers a release whose date is unknown', function()
      local aged, held = outdated.pick('1.0.0', {
        { version = '2.0.0' },
        { version = '1.5.0', time = NOW - 30 * DAY },
      }, NOW)
      assert.are.equal('1.5.0', aged.version)
      assert.are.equal('2.0.0', held.version)
      assert.is_nil(held.time)
    end)

    it('says nothing of a release no newer at the precision written', function()
      local aged, held = outdated.pick('v4', {
        { version = 'v4.2.2', time = NOW - 30 * DAY },
      }, NOW)
      assert.is_nil(aged)
      assert.is_nil(held)
    end)
  end)

  describe('registries', function()
    --- The versions of a package as deps.dev lists them
    local function deps_dev(versions)
      return {
        versions = vim.tbl_map(
          function(v)
            return {
              versionKey = { system = 'NPM', name = 'x', version = v[1] },
              publishedAt = v[2],
              isDeprecated = v[3] == true,
            }
          end,
          versions
        ),
      }
    end

    it('reads npm releases from deps.dev, deprecated ones left out', function()
      local releases = outdated.releases_of(
        'npm',
        deps_dev({
          { '1.0.0', ago(100 * DAY) },
          { '1.1.0', ago(10 * DAY) },
          { '1.2.0', ago(2 * DAY), true },
        })
      )
      assert.are.same(
        { '1.0.0', '1.1.0' },
        vim.tbl_map(function(r) return r.version end, releases)
      )
      assert.are.equal(NOW - 10 * DAY, releases[2].time)
    end)

    it('reads PyPI, a release with every file yanked left out', function()
      local releases = outdated.releases_of('pypi', {
        releases = {
          ['2.31.0'] = { { upload_time_iso_8601 = ago(200 * DAY) } },
          ['2.32.0'] = {
            { upload_time_iso_8601 = ago(20 * DAY), yanked = true },
          },
          ['2.32.1'] = {},
        },
      })
      assert.are.equal(1, #releases)
      assert.are.equal('2.31.0', releases[1].version)
    end)

    it('reads the Terraform registry and GitHub releases', function()
      local providers = outdated.releases_of('tf-provider', {
        included = {
          {
            type = 'provider-versions',
            attributes = { version = '5.1.0', ['published-at'] = ago(DAY) },
          },
          { type = 'other', attributes = {} },
        },
      })
      assert.are.same({ { version = '5.1.0', time = NOW - DAY } }, providers)
      local actions = outdated.releases_of('action', {
        { tag_name = 'v5.0.0', published_at = ago(DAY) },
        { tag_name = 'v5.1.0-rc', published_at = ago(DAY), prerelease = true },
        { tag_name = 'v6.0.0', draft = true },
      })
      assert.are.equal(2, #actions)
      assert.is_true(actions[2].prerelease)
    end)

    it(
      'escapes a Go module path as the proxy wants it',
      function()
        assert.are.equal(
          'github.com/!burnt!sushi/toml',
          outdated.go_escape('github.com/BurntSushi/toml')
        )
      end
    )
  end)

  describe('in a buffer', function()
    local dir, cleanup, path, notes, restore_notify, restore_time

    before_each(function()
      dir, cleanup = h.tmpdir()
      vim.fn.mkdir(dir .. '/bin', 'p')
      path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
      notes = {}
      restore_notify = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      restore_time = h.stub(outdated, 'now', function() return NOW end)
      -- npm through a fake curl: the versions of each package by its URL
      local versions = {}
      for _, v in ipairs({
        { '1.1.0', ago(400 * DAY) },
        { '1.3.0', ago(30 * DAY) },
        { '1.4.0', ago(DAY) },
      }) do
        table.insert(versions, {
          versionKey = { system = 'NPM', name = 'left-pad', version = v[1] },
          publishedAt = v[2],
        })
      end
      h.write(
        dir .. '/npm/left-pad',
        { vim.json.encode({ versions = versions }) }
      )
      h.write(dir .. '/bin/curl', {
        '#!/bin/sh',
        'for arg; do url=$arg; done',
        'echo "$url" >> "' .. dir .. '/calls"',
        'case "$url" in',
        '  https://api.deps.dev/v3/systems/npm/packages/left-pad) cat "'
          .. dir
          .. '/npm/left-pad" ;;',
        -- Two lines, as curl and jq together print them
        '  *) printf "404 %s\\nmore\\n" "$url" >&2; exit 22 ;;',
        'esac',
      })
      vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
    end)
    after_each(function()
      vim.env.PATH = path
      restore_notify()
      restore_time()
      vim.cmd('silent! %bwipeout!')
      cleanup()
    end)

    local function package_json()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/package.json'))
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '{',
        '  "dependencies": {',
        '    "left-pad": "^1.1.0",',
        '    "missing": "^2.0.0"',
        '  }',
        '}',
      })
      return bufnr
    end

    local function marks(bufnr)
      local found = {}
      for _, mark in
        ipairs(
          vim.api.nvim_buf_get_extmarks(
            bufnr,
            outdated.ns,
            0,
            -1,
            { details = true }
          )
        )
      do
        local text = vim.tbl_map(
          function(chunk) return chunk[1] end,
          mark[4].virt_text
        )
        found[mark[2] + 1] = table.concat(text)
      end
      return found
    end

    it('shows the release to move to, the one held, and a failure', function()
      local bufnr = package_json()
      local done = false
      outdated.check(bufnr, function() done = true end)
      vim.wait(5000, function() return done end)
      assert.is_true(done)
      local shown = marks(bufnr)
      assert.matches('1%.3%.0', shown[3])
      assert.matches('1%.4%.0 held', shown[3])
      assert.matches('404', shown[4])
      -- One line of the error, nothing of what follows it
      assert.is_nil(shown[4]:find('more', 1, true))
      assert.is_nil(shown[4]:find('%c'))
      assert.matches('1 of 2 .*behind', notes[#notes])
      assert.matches('1 failed', notes[#notes])
    end)

    it('asks a registry once per session for the same package', function()
      local bufnr = package_json()
      local done = 0
      outdated.check(bufnr, function() done = done + 1 end)
      vim.wait(5000, function() return done == 1 end)
      outdated.check(bufnr, function() done = done + 1 end)
      vim.wait(5000, function() return done == 2 end)
      local calls = vim.fn.readfile(dir .. '/calls')
      assert.are.equal(
        1,
        #vim.tbl_filter(
          function(call) return call:find('left-pad', 1, true) ~= nil end,
          calls
        )
      )
    end)

    it('drops what an earlier check hears once a later one starts', function()
      local bufnr = package_json()
      local first, second = false, false
      outdated.check(bufnr, function() first = true end)
      outdated.check(bufnr, function() second = true end)
      assert.is_true(vim.wait(5000, function() return first and second end))
      -- One mark per line, from the second check only
      assert.are.equal(
        2,
        #vim.api.nvim_buf_get_extmarks(bufnr, outdated.ns, 0, -1, {})
      )
    end)

    it('clears what it showed when the buffer changed meanwhile', function()
      local bufnr = package_json()
      local done = false
      outdated.check(bufnr, function() done = true end)
      vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { '' })
      assert.is_true(vim.wait(5000, function() return done end))
      assert.are.same(
        {},
        vim.api.nvim_buf_get_extmarks(bufnr, outdated.ns, 0, -1, {})
      )
      assert.matches('changed meanwhile', notes[#notes])
    end)

    it('bumps the line under the cursor to the release shown', function()
      local bufnr = package_json()
      local done = false
      outdated.check(bufnr, function() done = true end)
      vim.wait(5000, function() return done end)
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      outdated.bump(bufnr)
      assert.are.equal(
        '    "left-pad": "^1.3.0",',
        vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1]
      )
      assert.is_nil(marks(bufnr)[3])
      -- A failed line has nothing to bump to
      vim.api.nvim_win_set_cursor(0, { 4, 0 })
      outdated.bump(bufnr)
      assert.matches('Nothing to bump', notes[#notes])
    end)

    it('says when the buffer is no manifest it reads', function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
      outdated.check(0)
      assert.matches('Not a manifest', notes[#notes])
    end)
  end)
end)
