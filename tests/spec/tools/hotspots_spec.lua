local h = require('helpers')

describe('tools.hotspots', function()
  local hotspots, dir, root, cleanup, path, notes, restores, installed

  before_each(function()
    h.unload('tools.hotspots')
    hotspots = require('tools.hotspots')
    dir, cleanup = h.tmpdir()
    dir = vim.uv.fs_realpath(dir)
    root = dir .. '/proj'
    vim.fn.mkdir(dir .. '/bin', 'p')
    vim.fn.mkdir(root, 'p')
    path = vim.env.PATH
    -- The fakes of this spec and git, whatever else the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes, installed = {}, {}
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(package.loaded, 'util.lazy_install', {
        install_once = function(name) table.insert(installed, name) end,
      }),
      h.stub(
        package.loaded,
        'util.root',
        setmetatable({}, { __call = function() return root end })
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

  --- A fake lizard that keeps the files it was given and prints `out`
  local function fake_lizard(out, code)
    h.write(dir .. '/lizard.out', vim.split(out, '\n'))
    h.write(dir .. '/bin/lizard', {
      '#!/bin/sh',
      -- `--csv -f list`
      'cat "$3" > "' .. dir .. '/lizard.files"',
      'cat "' .. dir .. '/lizard.out"',
      'exit ' .. (code or 0),
    })
    vim.fn.setfperm(dir .. '/bin/lizard', 'rwxr-xr-x')
  end

  local function git(...)
    local result = vim
      .system({
        'git',
        '-c',
        'user.name=t',
        '-c',
        'user.email=t@t',
        '-c',
        'commit.gpgsign=false',
        ...,
      }, { cwd = root })
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  --- Commit `files`, each with a new line
  local function commit(files)
    for _, file in ipairs(files) do
      vim.fn.mkdir(vim.fs.dirname(root .. '/' .. file), 'p')
      vim.fn.writefile({ tostring(vim.uv.hrtime()) }, root .. '/' .. file, 'a')
    end
    git('add', '-A')
    git('commit', '-q', '-m', 'c')
  end

  local function noted(pattern)
    return vim.wait(5000, function()
      for _, note in ipairs(notes) do
        if note.msg:match(pattern) then return true end
      end
      return false
    end)
  end

  local function csv(file, name, ccn, lnum)
    return ('%d,%d,10,1,5,"%s@%d-%d@%s","%s","%s","%s( )",%d,%d'):format(
      5,
      ccn,
      name,
      lnum,
      lnum + 4,
      file,
      file,
      name,
      name,
      lnum,
      lnum + 4
    )
  end

  it('ranks tracked files by commits times complexity', function()
    git('init', '-q')
    commit({ 'a.lua', 'b.lua', 'yarn.lock', 'vendor/v.lua' })
    commit({ 'a.lua', 'gone.lua' })
    commit({ 'a.lua', 'b.lua' })
    git('rm', '-q', 'gone.lua')
    git('commit', '-q', '-m', 'rm')
    fake_lizard(table.concat({
      csv('a.lua', 'small', 2, 1),
      csv('a.lua', 'worse', 3, 10),
      csv('b.lua', 'big', 9, 20),
    }, '\n'))
    hotspots.run()
    assert.is_true(
      vim.wait(5000, function() return #vim.fn.getqflist() > 0 end)
    )
    local files = vim.fn.readfile(dir .. '/lizard.files')
    table.sort(files)
    assert.same({ 'a.lua', 'b.lua' }, files)
    local items = vim.fn.getqflist()
    -- b: 2 commits x 9, a: 3 commits x (2 + 3)
    assert.equals(root .. '/b.lua', vim.api.nvim_buf_get_name(items[1].bufnr))
    assert.equals(20, items[1].lnum)
    assert.equals(
      'score 18: 2 commits x CCN 9; worst big (CCN 9)',
      items[1].text
    )
    assert.equals(root .. '/a.lua', vim.api.nvim_buf_get_name(items[2].bufnr))
    assert.equals(10, items[2].lnum)
    assert.equals(
      'score 15: 3 commits x CCN 5; worst worse (CCN 3)',
      items[2].text
    )
    assert.equals('Hotspots', vim.fn.getqflist({ title = 0 }).title)
  end)

  it('says so outside a git repository', function()
    fake_lizard('')
    hotspots.run()
    assert.is_true(noted('Not a git repository'))
  end)

  it('has Mason install lizard and never says nothing was found', function()
    git('init', '-q')
    commit({ 'a.lua' })
    hotspots.run()
    assert.is_true(noted('lizard is not installed'))
    assert.same({ 'lizard' }, installed)
    assert.is_false(noted('^No '))
  end)

  it('reports a failed lizard run', function()
    git('init', '-q')
    commit({ 'a.lua' })
    fake_lizard('', 2)
    hotspots.run()
    assert.is_true(noted('lizard exited 2'))
    assert.is_false(noted('^No '))
  end)

  it('skips generated and vendored files', function()
    assert.is_true(hotspots.excluded('package-lock.json'))
    assert.is_true(hotspots.excluded('pnpm-lock.yaml'))
    assert.is_true(hotspots.excluded('Cargo.lock'))
    assert.is_true(hotspots.excluded('sub/go.sum'))
    assert.is_true(hotspots.excluded('node_modules/x/i.js'))
    assert.is_true(hotspots.excluded('web/vendor/x.php'))
    assert.is_true(hotspots.excluded('dist/app.min.js'))
    assert.is_false(hotspots.excluded('lua/tools/vendors.lua'))
    assert.is_false(hotspots.excluded('src/clock.c'))
  end)

  it('toggles hints on the complex functions of the buffer', function()
    hotspots.CCN_WARN = 5
    local file = root .. '/m.lua'
    h.write(file, { 'x', 'x', 'x', 'x', 'x', 'x', 'x', 'x' })
    vim.cmd.edit(file)
    local bufnr = vim.api.nvim_get_current_buf()
    fake_lizard(
      table.concat({ csv(file, 'calm', 2, 1), csv(file, 'wild', 7, 3) }, '\n')
    )
    local ns = vim.api.nvim_create_namespace('dy_hotspots')
    hotspots.buffer()
    assert.is_true(
      vim.wait(
        5000,
        function() return #vim.diagnostic.get(bufnr, { namespace = ns }) > 0 end
      )
    )
    local diagnostics = vim.diagnostic.get(bufnr, { namespace = ns })
    assert.equals(1, #diagnostics)
    assert.equals(2, diagnostics[1].lnum)
    assert.equals(vim.diagnostic.severity.HINT, diagnostics[1].severity)
    assert.matches('wild: cyclomatic complexity 7', diagnostics[1].message)
    hotspots.buffer()
    assert.equals(0, #vim.diagnostic.get(bufnr, { namespace = ns }))
    assert.equals(
      0,
      #vim.api.nvim_get_autocmds({ event = 'BufWritePost', buffer = bufnr })
    )
    vim.cmd('bwipeout!')
  end)
end)
