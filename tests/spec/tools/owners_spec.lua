local h = require('helpers')

describe('tools.owners', function()
  local owners, dir, cleanup, notes, restore_notify

  before_each(function()
    h.unload('tools.owners')
    owners = require('tools.owners')
    dir, cleanup = h.tmpdir()
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function()
    restore_notify()
    vim.cmd('silent! cclose')
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('matches globs, `*` within a folder and `**` across them', function()
    local cases = {
      { '*.js', 'a.js', true },
      { '*.js', 'a/b.js', false },
      { '**/*.js', 'a/b.js', true },
      { '**/*.js', 'b.js', true },
      { 'docs/**', 'docs/a/b.md', true },
      { 'a/**/b', 'a/b', true },
      { 'a/**/b', 'a/x/y/b', true },
      { 'a?c', 'abc', true },
      { 'a?c', 'a/c', false },
      { 'a\\*b', 'a*b', true },
      { 'a\\*b', 'axb', false },
    }
    for _, case in ipairs(cases) do
      assert.equals(
        case[3],
        owners.glob_match(case[1], case[2]),
        case[1] .. ' ' .. case[2]
      )
    end
  end)

  --- The owners of each path under the rules of `lines`
  local function owned(lines, paths)
    local rules = owners.parse(lines)
    local found = {}
    for _, path in ipairs(paths) do
      found[path] = table.concat((owners.owners(rules, path)), ' ')
    end
    return found
  end

  it(
    "reads GitHub's examples, the last match winning",
    function()
      assert.same(
        {
          ['README.md'] = '@global-owner1 @global-owner2',
          ['src/app.js'] = '@js-owner',
          ['build/logs/x.log'] = '@doctocat',
          ['src/build/logs/x.log'] = '@global-owner1 @global-owner2',
          ['docs/getting-started.md'] = 'docs@example.com',
          ['docs/build-app/troubleshooting.md'] = '@global-owner1 @global-owner2',
          ['apps/web/main.go'] = '@octocat',
          ['a/apps/web/main.go'] = '@octocat',
          ['scripts/x.sh'] = '@doctocat @octocat',
          ['config/x.yml'] = '',
          ['config/sub/x.yml'] = '',
        },
        owned({
          '# comment',
          '*       @global-owner1 @global-owner2',
          '*.js    @js-owner #This is an inline comment.',
          '/build/logs/ @doctocat',
          'docs/*  docs@example.com',
          'apps/ @octocat',
          '/scripts/ @doctocat @octocat',
          '/config/',
        }, {
          'README.md',
          'src/app.js',
          'build/logs/x.log',
          'src/build/logs/x.log',
          'docs/getting-started.md',
          'docs/build-app/troubleshooting.md',
          'apps/web/main.go',
          'a/apps/web/main.go',
          'scripts/x.sh',
          'config/x.yml',
          'config/sub/x.yml',
        })
      )
    end
  )

  it("sums the owners of each of GitLab's sections", function()
    assert.same(
      {
        ['README.md'] = '@all @docs-team',
        ['docs/x.md'] = '@all @docs-team',
        ['src/x.rb'] = '@all @backend',
        ['src/api/x.rb'] = '@all @api',
      },
      owned({
        '* @all',
        '[Documentation] @docs-team',
        '*.md',
        'docs/',
        '^[Backend][2] @backend',
        'src/',
        'src/api/ @api',
      }, { 'README.md', 'docs/x.md', 'src/x.rb', 'src/api/x.rb' })
    )
    local rules = owners.parse({ '[Docs] @d', 'README.md' })
    assert.equals('Docs', rules[1].section)
    assert.same({ '@d' }, rules[1].owners)
  end)

  it('reads a `**` not beside a slash as a `*`', function()
    assert.is_false(owners.glob_match('**.md', 'src/x.lua'))
    assert.is_true(owners.glob_match('**.md', 'x.md'))
    assert.same(
      { ['docs/x.lua'] = '', ['docs/x.md'] = '@a' },
      owned({ '/docs/**.md @a' }, { 'docs/x.lua', 'docs/x.md' })
    )
  end)

  it("reads GitLab's sections in any case, its paths at any depth", function()
    assert.same(
      { ['a'] = '@y' },
      owned({ '[Sec]', 'a @x', '[sec]', 'a @y' }, { 'a' })
    )
    -- GitLab: a relative path is matched at any depth
    local rules = owners.parse({ 'internal/README.md @g' }, true)
    assert.same({ '@g' }, (owners.owners(rules, 'docs/internal/README.md')))
    -- GitHub: anchored at the root
    rules = owners.parse({ 'internal/README.md @g' }, false)
    assert.same({}, (owners.owners(rules, 'docs/internal/README.md')))
  end)

  it(
    'keeps an escaped space in a pattern',
    function()
      assert.same(
        { ['my file.txt'] = '@o' },
        owned({ 'my\\ file.txt @o' }, { 'my file.txt' })
      )
    end
  )

  describe('in a repository', function()
    local function git(args)
      local result = require('util.system').sync(
        vim.list_extend({ 'git' }, args),
        { cwd = dir, timeout = 10000 }
      )
      assert.equals(0, result.code, result.stderr)
    end

    before_each(function()
      git({ 'init', '-q' })
      h.write(dir .. '/.github/CODEOWNERS', {
        '* @team',
        '/docs/ @writers',
        '/vendor/',
      })
      h.write(dir .. '/src/a.lua', {})
      h.write(dir .. '/docs/b.md', {})
      h.write(dir .. '/vendor/c.js', {})
      h.write(dir .. '/vendor/d.js', {})
    end)

    it('names the owners of the buffer and the line that made them', function()
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/docs/b.md'))
      owners.show()
      local said = vim.split(notes[1], '\n')
      assert.equals('@writers', said[1])
      assert.is_truthy(said[2]:find('%.github/CODEOWNERS:2 `/docs/`$'))
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/vendor/c.js'))
      owners.show()
      assert.is_truthy(notes[2]:find('Unowned: .*:3 `/vendor/` names nobody'))
    end)

    it(
      'shows them on the statusline, from a cache CODEOWNERS empties',
      function()
        vim.cmd.edit(vim.fn.fnameescape(dir .. '/src/a.lua'))
        assert.equals('@team', owners.statusline())
        h.write(dir .. '/.github/CODEOWNERS', { '* @others' })
        -- Within the recheck the answer stands
        assert.equals('@team', owners.statusline())
        local restore = h.stub(owners, 'RECHECK', -1)
        -- A file rewritten within the same second still has a new mtime here
        vim.uv.fs_utime(
          dir .. '/.github/CODEOWNERS',
          os.time() + 5,
          os.time() + 5
        )
        assert.equals('@others', owners.statusline())
        restore()
        vim.cmd.edit(vim.fn.fnameescape(dir .. '/docs/b.md'))
        vim.bo.buftype = 'nofile'
        assert.equals('', owners.statusline())
      end
    )

    it('says nothing on the statusline without CODEOWNERS', function()
      vim.fn.delete(dir .. '/.github', 'rf')
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/src/a.lua'))
      assert.equals('', owners.statusline())
      owners.show()
      assert.equals('No CODEOWNERS in the repository of this file', notes[1])
    end)

    it('lists the files git tracks that nobody owns', function()
      git({ 'add', '.' })
      vim.cmd.edit(vim.fn.fnameescape(dir .. '/src/a.lua'))
      local restore = h.stub(owners, 'CHUNK', 1)
      local done = false
      owners.unowned(function() done = true end)
      assert.is_true(vim.wait(10000, function() return done end, 10))
      restore()
      assert.equals('2 of 5 files have no owner', notes[#notes])
      local names = vim.tbl_map(
        function(item) return vim.fn.bufname(item.bufnr):match('[^/]+$') end,
        vim.fn.getqflist()
      )
      table.sort(names)
      assert.same({ 'c.js', 'd.js' }, names)
    end)
  end)
end)
