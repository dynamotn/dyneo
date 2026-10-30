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

    it('reads dependency groups and Poetry groups, no other table', function()
      local deps = read('pyproject', {
        '[dependency-groups]',
        'test = ["pytest>=8.0"]',
        '[tool.poetry.group.lint.dependencies]',
        'black = "^24.1"',
        '[tool.ruff]',
        'target = "^3.12"',
      })
      assert.are.same(
        { { 'pytest', '8.0', 2 }, { 'black', '24.1', 4 } },
        vim.tbl_map(
          function(dep) return { dep.name, dep.version, dep.line } end,
          deps
        )
      )
    end)

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

    it('tells a range with a second bound from one version', function()
      local function ranges(reader, lines)
        return vim.tbl_map(
          function(dep) return { dep.name, dep.version, dep.range == true } end,
          read(reader, lines)
        )
      end
      assert.are.same(
        {
          { 'a', '1.0.0', true },
          { 'b', '1.0.0', true },
          { 'c', '1.0', true },
          { 'd', '1.2.0', false },
          { 'e', '1.0', false },
        },
        ranges('npm', {
          '{',
          '  "dependencies": {',
          '  "a": ">=1.0.0 <2.0.0",',
          '  "b": "1.0.0 - 2.0.0",',
          '  "c": "^1.0 || ^2.0",',
          '  "d": "~1.2.0",',
          '  "e": ">=1.0"',
          '  }',
          '}',
        })
      )
      assert.are.same(
        {
          { 'django', '3.2', true },
          { 'httpx', '2.0', true },
          { 'rich', '13.7.1', false },
          { 'h2', '4.0', false },
        },
        ranges('pypi', {
          'django>=3.2,<4',
          'httpx<2.0',
          'rich==13.7.1',
          'h2[http2]>=4.0',
        })
      )
      assert.are.same(
        { { 'pydantic', '2.0', true }, { 'boto3', '1.34', false } },
        ranges('pyproject', {
          '[tool.poetry.dependencies]',
          'pydantic = ">=2.0,<3.0"',
          'boto3 = "^1.34"',
        })
      )
      assert.are.same(
        {
          { 'hashicorp/aws', '4.0', true },
          { 'hashicorp/random', '3.5', false },
        },
        ranges('terraform', {
          'terraform {',
          '  required_providers {',
          '    aws = { source = "hashicorp/aws", version = ">= 4.0, < 6.0" }',
          '    random = { source = "hashicorp/random", version = "~> 3.5" }',
          '  }',
          '}',
        })
      )
    end)
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

    it('names no release held that reads as the one offered', function()
      local aged, held = outdated.pick('1.0', {
        { version = '1.1.0', time = NOW - 30 * DAY },
        { version = '1.1.5', time = NOW - DAY },
      }, NOW)
      assert.are.equal('1.1.0', aged.version)
      assert.is_nil(held)
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
      local modules = outdated.releases_of('tf-module', {
        included = {
          {
            type = 'module-versions',
            attributes = { version = '5.2.0', ['published-at'] = ago(DAY) },
          },
          {
            type = 'provider-versions',
            attributes = { version = '9.9.9' },
          },
        },
      })
      assert.are.same({ { version = '5.2.0', time = NOW - DAY } }, modules)
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

    it('keeps what GOPRIVATE names off the public Go proxy', function()
      local restore =
        h.stub(vim.env, 'GOPRIVATE', '*.corp.example,github.com/acme')
      local private = outdated.go_private('git.corp.example/team/svc')
      local org = outdated.go_private('github.com/acme/tool')
      local other = outdated.go_private('github.com/acmeco/tool')
      -- An empty GONOPROXY is unset, and `go env` answers before either
      local unset = h.stub(vim.env, 'GONOPROXY', '')
      local fallback = outdated.go_private('github.com/acme/tool')
      local from_go = outdated.go_private('example.com/x', 'example.com')
      unset()
      restore()
      assert.is_true(private)
      assert.is_true(org)
      assert.is_false(other)
      assert.is_true(fallback)
      assert.is_true(from_go)
    end)
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
        "  https://api.deps.dev/v3/systems/npm/packages/gone) echo '{}' ;;",
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

    it('shows a range its release but never writes it in', function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/package.json'))
      local bufnr = vim.api.nvim_get_current_buf()
      local range = '    "left-pad": ">=1.1.0 <1.2.0"'
      vim.api.nvim_buf_set_lines(
        bufnr,
        0,
        -1,
        false,
        { '{', '  "dependencies": {', range, '  }', '}' }
      )
      local done = false
      outdated.check(bufnr, function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end))
      assert.matches('1%.3%.0.*a range', marks(bufnr)[3])
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      outdated.bump(bufnr)
      assert.are.equal(range, vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1])
      assert.matches('is a range', notes[#notes])
    end)

    it('says when a registry lists no release, not up to date', function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/package.json'))
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '{',
        '  "dependencies": {',
        '    "gone": "^1.0.0"',
        '  }',
        '}',
      })
      local done = false
      outdated.check(bufnr, function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end))
      assert.matches('no release listed', marks(bufnr)[3])
      assert.matches('0 of 1 .*, 1 with no release listed', notes[#notes])
    end)

    it('says when the buffer is no manifest it reads', function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
      outdated.check(0)
      assert.matches('Not a manifest', notes[#notes])
    end)

    it('cuts a long error to the width of one line', function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/package.json'))
      local bufnr = vim.api.nvim_get_current_buf()
      local name = ('long-'):rep(20)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
        '{',
        '  "dependencies": {',
        '    "' .. name .. '": "^1.0.0"',
        '  }',
        '}',
      })
      local done = false
      outdated.check(bufnr, function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end))
      local shown = marks(bufnr)[3]
      assert.matches('^  %? 404 https://api%.deps%.dev/', shown)
      assert.matches('…$', shown)
      assert.are.equal(
        outdated.ERROR_WIDTH,
        vim.fn.strchars(shown) - vim.fn.strchars('  ? ')
      )
    end)

    it('bumps nothing once the version left the line', function()
      local bufnr = package_json()
      local done = false
      outdated.check(bufnr, function() done = true end)
      assert.is_true(vim.wait(5000, function() return done end))
      -- `^1.1.0` becomes `^1.2.0`, the mark staying where it was
      vim.api.nvim_buf_set_text(bufnr, 2, 20, 2, 21, { '2' })
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      outdated.bump(bufnr)
      assert.are.equal(
        '    "left-pad": "^1.2.0",',
        vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1]
      )
      assert.matches('1%.1%.0 is no longer on this line', notes[#notes])
    end)

    it('says when curl is not installed, asking nothing', function()
      local bufnr = package_json()
      local executable = vim.fn.executable
      local restore = h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'curl' and 0 or executable(name) end
      )
      outdated.check(bufnr)
      restore()
      assert.matches('curl is not installed', notes[#notes])
      assert.are.equal(0, vim.fn.filereadable(dir .. '/calls'))
    end)

    it('checks, bumps and clears the current buffer by subcommand', function()
      local bufnr = package_json()
      outdated.command({ fargs = {} })
      assert.matches('Asking about 2', notes[#notes])
      assert.is_true(
        vim.wait(
          5000,
          function() return notes[#notes]:find('behind', 1, true) ~= nil end
        )
      )
      vim.api.nvim_win_set_cursor(0, { 3, 0 })
      outdated.command({ fargs = { 'bump' } })
      assert.matches('left%-pad: 1%.1%.0 → 1%.3%.0', notes[#notes])
      assert.is_not_nil(marks(bufnr)[4])
      outdated.command({ fargs = { 'clear' } })
      assert.are.same({}, marks(bufnr))
      assert.is_nil(outdated.found[bufnr])
      outdated.command({ fargs = { 'nope' } })
      assert.are.equal('Unknown subcommand: nope', notes[#notes])
    end)

    describe('each registry', function()
      --- Serve `body` at `url` through the fake curl
      local function serve(url, body)
        h.write(dir .. '/web/' .. url:gsub('[^%w]', '_'), vim.split(body, '\n'))
      end
      --- Check a buffer holding `lines` at `name`, and give what it shows
      local function check(name, lines)
        local file = dir .. '/' .. name
        vim.fn.mkdir(vim.fs.dirname(file), 'p')
        vim.cmd.edit(vim.fn.fnameescape(file))
        local bufnr = vim.api.nvim_get_current_buf()
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
        local done = false
        outdated.check(bufnr, function() done = true end)
        assert.is_true(vim.wait(5000, function() return done end))
        return marks(bufnr), bufnr
      end
      local function calls()
        if vim.fn.filereadable(dir .. '/calls') == 0 then return {} end
        return vim.fn.readfile(dir .. '/calls')
      end

      before_each(function()
        -- Any URL served by `serve`, the others failing as curl does
        h.write(dir .. '/bin/curl', {
          '#!/bin/sh',
          'for arg; do url=$arg; done',
          'echo "$url" >> "' .. dir .. '/calls"',
          'file="'
            .. dir
            .. '/web/$(printf %s "$url" | tr -c \'A-Za-z0-9\' _)"',
          '[ -f "$file" ] || { echo "404 $url" >&2; exit 22; }',
          'cat "$file"',
        })
        vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
      end)

      it('asks PyPI through jq, keeping only times and flags', function()
        h.write(dir .. '/bin/jq', {
          '#!/bin/sh',
          'printf %s "$2" > "' .. dir .. '/filter"',
          'cat',
        })
        vim.fn.setfperm(dir .. '/bin/jq', 'rwxr-xr-x')
        serve(
          'https://pypi.org/pypi/requests/json',
          vim.json.encode({
            releases = {
              ['2.32.0'] = { { upload_time_iso_8601 = ago(20 * DAY) } },
            },
          })
        )
        local shown = check('requirements.txt', { 'requests==2.31.0' })
        assert.are.equal('  → 2.32.0', shown[1])
        assert.matches(
          'upload_time_iso_8601, yanked',
          vim.fn.readfile(dir .. '/filter')[1]
        )
      end)

      it(
        'says when a registry answers more than it reads, or no JSON',
        function()
          serve(
            'https://api.deps.dev/v3/systems/npm/packages/big',
            ('x'):rep(64)
          )
          serve('https://api.deps.dev/v3/systems/npm/packages/text', 'oops')
          local restore = h.stub(outdated, 'MAX_BYTES', 32)
          local shown = check('package.json', {
            '{',
            '  "dependencies": { "big": "^1.0.0" },',
            '  "devDependencies": { "text": "^1.0.0" }',
            '}',
          })
          restore()
          assert.matches('more than can be read', shown[2])
          assert.matches('something not JSON', shown[3])
          assert.matches('2 failed', notes[#notes])
        end
      )

      it('asks the Go proxy newest first until a release is aged', function()
        local text = 'https://proxy.golang.org/golang.org/x/text/@v/'
        serve(text .. 'list', 'v0.20.0\nv0.21.0\nv0.22.0\nv0.23.0-rc1')
        serve(text .. 'v0.22.0.info', vim.json.encode({ Time = ago(DAY) }))
        serve(text .. 'v0.21.0.info', vim.json.encode({ Time = ago(30 * DAY) }))
        serve('https://proxy.golang.org/example.com/done/@v/list', 'v1.0.0')
        serve('https://proxy.golang.org/example.com/new/@v/list', 'v2.0.0')
        local shown = check('go.mod', {
          'module example.com/app',
          'require (',
          '\tgolang.org/x/text v0.20.0',
          '\texample.com/done v1.0.0',
          '\texample.com/new v1.0.0',
          '\texample.com/gone v1.0.0',
          ')',
        })
        assert.are.equal('  → v0.21.0  v0.22.0 held, 1d old', shown[3])
        -- Up to date: the newest listed is the version written
        assert.is_nil(shown[4])
        -- A release whose date the proxy did not give is held
        assert.are.equal('  v2.0.0 held, date unknown', shown[5])
        assert.matches('^  %? 404 https://proxy%.golang%.org/', shown[6])
        local asked = calls()
        assert.is_true(vim.tbl_contains(asked, text .. 'v0.22.0.info'))
        assert.is_false(vim.tbl_contains(asked, text .. 'v0.20.0.info'))
        assert.is_false(vim.tbl_contains(asked, text .. 'v0.23.0-rc1.info'))
      end)

      it('asks the Go proxy no more than its lookups allow', function()
        local toml = 'https://proxy.golang.org/github.com/!burnt!sushi/toml/@v/'
        serve(toml .. 'list', 'v1.1.0\nv1.2.0')
        serve(toml .. 'v1.2.0.info', vim.json.encode({ Time = ago(0) }))
        serve(toml .. 'v1.1.0.info', vim.json.encode({ Time = ago(90 * DAY) }))
        local restore = h.stub(outdated, 'GO_LOOKUPS', 1)
        local shown = check('go.mod', {
          'module example.com/app',
          'require github.com/BurntSushi/toml v1.0.0',
        })
        restore()
        assert.are.equal('  v1.2.0 held, out today', shown[2])
        assert.is_false(vim.tbl_contains(calls(), toml .. 'v1.1.0.info'))
      end)

      it('asks the Terraform registry of providers and modules', function()
        local function versions(kind, version)
          return vim.json.encode({
            included = {
              {
                type = kind,
                attributes = {
                  version = version,
                  ['published-at'] = ago(30 * DAY),
                },
              },
            },
          })
        end
        serve(
          'https://registry.terraform.io/v2/providers/hashicorp/aws'
            .. '?include=provider-versions',
          versions('provider-versions', '5.40.0')
        )
        serve(
          'https://registry.terraform.io/v2/modules/'
            .. 'terraform-aws-modules/vpc/aws?include=module-versions',
          versions('module-versions', '5.8.1')
        )
        local shown = check('versions.tf', {
          'terraform {',
          '  required_providers {',
          '    aws = { source = "hashicorp/aws", version = "~> 5.0" }',
          '  }',
          '}',
          'module "vpc" {',
          '  source  = "terraform-aws-modules/vpc/aws"',
          '  version = "5.1.0"',
          '}',
        })
        assert.are.equal('  → 5.40', shown[3])
        assert.are.equal('  → 5.8.1', shown[8])
      end)

      it('asks GitHub through gh, and bumps no pinned action', function()
        local sha = ('a'):rep(40)
        local releases = vim.json.encode({
          { tag_name = 'v5.0.0', published_at = ago(30 * DAY) },
        })
        h.write(dir .. '/bin/gh', {
          '#!/bin/sh',
          'echo "$*" >> "' .. dir .. '/gh-calls"',
          'case "$2" in',
          "  repos/actions/*) echo '" .. releases .. "' ;;",
          '  *) echo "HTTP 404" >&2; exit 1 ;;',
          'esac',
        })
        vim.fn.setfperm(dir .. '/bin/gh', 'rwxr-xr-x')
        local shown, bufnr = check('.github/workflows/ci.yml', {
          'steps:',
          '  - uses: actions/checkout@v4',
          '  - uses: actions/cache@' .. sha .. ' # v4.1.2',
          '  - uses: o/missing@v1',
        })
        assert.are.equal('  → v5', shown[2])
        assert.are.equal('  → v5.0.0  (pinned: :DyActionsPin)', shown[3])
        assert.matches('HTTP 404', shown[4])
        assert.are.same({}, calls())
        assert.is_true(
          vim.tbl_contains(
            vim.fn.readfile(dir .. '/gh-calls'),
            'api repos/actions/checkout/releases?per_page=100'
          )
        )
        vim.api.nvim_win_set_cursor(0, { 3, 0 })
        outdated.bump(bufnr)
        assert.matches('Pinned to a commit', notes[#notes])
        assert.matches(
          sha,
          vim.api.nvim_buf_get_lines(bufnr, 2, 3, false)[1],
          1,
          true
        )
      end)

      it('asks GitHub anonymously when gh is not installed', function()
        serve(
          'https://api.github.com/repos/actions/checkout/releases?per_page=100',
          vim.json.encode({
            { tag_name = 'v5.0.0', published_at = ago(30 * DAY) },
          })
        )
        local executable = vim.fn.executable
        local restore = h.stub(
          vim.fn,
          'executable',
          function(name) return name == 'gh' and 0 or executable(name) end
        )
        local shown = check(
          '.github/workflows/ci.yml',
          { 'steps:', '  - uses: actions/checkout@v4' }
        )
        restore()
        assert.are.equal('  → v5', shown[2])
      end)
    end)
  end)
end)
