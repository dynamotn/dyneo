local h = require('helpers')

describe('tools.project', function()
  local project, dir, cleanup, path

  local function git(...)
    local result = vim
      .system(
        vim.list_extend(
          { 'git', '-c', 'user.name=t', '-c', 'user.email=t@t' },
          { ... }
        ),
        { cwd = dir }
      )
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  local function cli(name, lines)
    h.write(dir .. '/bin/' .. name, vim.list_extend({ '#!/bin/sh' }, lines))
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  before_each(function()
    h.unload('tools.project', 'tools.ci_inline', 'util.forge', 'util.scratch')
    project = require('tools.project')
    dir, cleanup = h.tmpdir()
    path = vim.env.PATH
    vim.fn.mkdir(dir .. '/bin', 'p')
    -- No jira CLI, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
  end)
  after_each(function()
    vim.env.PATH = path
    vim.cmd('silent! tabonly!')
    vim.cmd('silent! %bwipeout!')
    vim.diagnostic.reset()
    cleanup()
  end)

  it('lays the sections out in order, items capped', function()
    project.LIMIT = 2
    local sections = {
      jira = { title = 'Jira', state = 'skipped', note = 'no CLI', items = {} },
      git = {
        title = 'Git',
        state = 'done',
        note = 'main',
        items = { { text = 'a', file = '/a' }, { text = 'b' }, { text = 'c' } },
      },
      tasks = project.section('tasks'),
    }
    local lines, items, headings = project.render('/r', sections)
    assert.same({
      'Project /r',
      '',
      'Git — main',
      '  a',
      '  b',
      '  … and 1 more',
      '',
      'Tasks …',
      '',
      'Jira — no CLI',
    }, lines)
    assert.equals('/a', items[4].file)
    assert.is_nil(items[6])
    assert.same({ 3, 8, 10 }, headings)
  end)

  it('reads the branch, what is unpushed and what is changed', function()
    git('init', '-q', '-b', 'release/1.2')
    h.write(dir .. '/a.txt', { 'a' })
    git('add', 'a.txt')
    git('commit', '-q', '-m', 'first')
    h.write(dir .. '/old name.txt', { 'o' })
    git('add', 'old name.txt')
    git('commit', '-q', '-m', 'second')
    h.write(dir .. '/a.txt', { 'b' })
    h.write(dir .. '/new.txt', { 'n' })
    h.write(dir .. '/é b.txt', { 'n' })
    git('mv', 'old name.txt', 'new name.txt')
    local got
    project.git(
      dir,
      function(state, note, items) got = { state, note, items } end
    )
    assert.is_true(vim.wait(5000, function() return got ~= nil end, 10))
    assert.equals('done', got[1])
    assert.equals('release/1.2, 0 ahead, 0 behind, 4 changed', got[2])
    assert.same(
      { ' M a.txt', 'R  new name.txt', '?? new.txt', '?? é b.txt' },
      vim.tbl_map(function(item) return item.text end, got[3])
    )
    assert.equals(dir .. '/a.txt', got[3][1].file)
    assert.equals(dir .. '/new name.txt', got[3][2].file)
    assert.equals(dir .. '/é b.txt', got[3][4].file)

    got = nil
    project.git(dir .. '/bin', function(state, note) got = { state, note } end)
    assert.is_true(vim.wait(5000, function() return got ~= nil end, 10))
    -- `bin` is inside the repository, so git still answers
    assert.equals('done', got[1])
  end)

  it('counts the diagnostics of the project, errors first', function()
    local ns = vim.api.nvim_create_namespace('project_spec')
    local inside = h.buffer({ name = dir .. '/x.lua', lines = { 'a', 'b' } })
    local worse = h.buffer({ name = dir .. '/y.lua', lines = { 'a', 'b' } })
    local outside = h.buffer({ name = '/elsewhere/z.lua', lines = { 'a' } })
    local E, W = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
    vim.diagnostic.set(
      ns,
      inside,
      { { lnum = 0, col = 0, message = 'w', severity = W } }
    )
    vim.diagnostic.set(ns, worse, {
      { lnum = 1, col = 0, message = 'e', severity = E },
      { lnum = 0, col = 0, message = 'e', severity = E },
    })
    vim.diagnostic.set(
      ns,
      outside,
      { { lnum = 0, col = 0, message = 'e', severity = E } }
    )
    local got
    project.diagnostics(
      dir,
      function(state, note, items) got = { state, note, items } end
    )
    assert.equals('2 errors, 1 warnings in open buffers', got[2])
    assert.equals(2, #got[3])
    assert.equals(dir .. '/y.lua', got[3][1].file)
    assert.equals(2, got[3][1].lnum)
  end)

  it('orders files with as many errors by warnings, then by name', function()
    local ns = vim.api.nvim_create_namespace('project_spec')
    local E, W = vim.diagnostic.severity.ERROR, vim.diagnostic.severity.WARN
    local function file(name, warnings)
      local bufnr = h.buffer({ name = dir .. '/' .. name, lines = { 'a' } })
      local list = { { lnum = 0, col = 0, message = 'e', severity = E } }
      for _ = 1, warnings do
        table.insert(list, { lnum = 0, col = 0, message = 'w', severity = W })
      end
      vim.diagnostic.set(ns, bufnr, list)
    end
    file('c.lua', 1)
    file('b.lua', 1)
    file('a.lua', 0)
    local got
    project.diagnostics(dir, function(_, _, items) got = items end)
    assert.same(
      { dir .. '/b.lua', dir .. '/c.lua', dir .. '/a.lua' },
      vim.tbl_map(function(item) return item.file end, got)
    )
  end)

  it('lists the tasks overseer knows, and says when it cannot', function()
    local got
    local function set(...) got = { ... } end
    project.tasks(set)
    assert.same({ 'skipped', 'no task run yet' }, got)

    local restore = h.stub(package.loaded, 'overseer', {
      list_tasks = function()
        return { { status = 'RUNNING', name = 'build' }, {} }
      end,
    })
    project.tasks(set)
    assert.equals('2 tasks', got[2])
    assert.same(
      { { text = 'RUNNING   build' }, { text = '?         ?' } },
      got[3]
    )
    restore()

    restore = h.stub(package.loaded, 'overseer', {
      list_tasks = function() error('not loaded') end,
    })
    project.tasks(set)
    restore()
    assert.same({ 'failed', 'overseer could not list its tasks' }, got)
  end)

  it('reads the last run of a GitHub branch, or says there is none', function()
    cli('gh', {
      'case "$*" in',
      [[  *branch=main*) echo '{"workflow_runs":[{"id":5,"name":"CI","status":"completed","conclusion":"success","html_url":"https://g/r/5"}]}';;]],
      [[  *) echo '{"workflow_runs":[]}';;]],
      'esac',
    })
    local remote = { kind = 'github', host = 'github.com', slug = 'o/r' }
    local got, none
    project.pipeline(remote, 'main', function(...) got = { ... } end)
    project.pipeline(remote, 'feat/x', function(...) none = { ... } end)
    assert.is_true(vim.wait(5000, function() return got and none end, 10))
    assert.same({ text = '✓ pass CI', url = 'https://g/r/5' }, got[3][1])
    assert.same({ 'done', 'no pipeline on feat/x' }, none)
  end)

  it('lists the Jira issues assigned', function()
    cli('jira', { 'exit 1' })
    local jira = require('tools.jira')
    local restore = h.stub(
      jira,
      'run',
      function(_, on_done) on_done(true, { 'OPS-1\tBug\tTo Do\tFix it' }, '') end
    )
    local got
    project.jira(function(...) got = { ... } end)
    restore()
    assert.equals('1 assigned', got[2])
    assert.same({ { text = 'OPS-1 [To Do] Fix it', jira = 'OPS-1' } }, got[3])
  end)

  it('lists open requests and the last pipeline of a GitLab project', function()
    cli('glab', {
      'case "$*" in',
      [[  *merge_requests*) echo '[{"iid":3,"title":"Add x","web_url":"https://g/mr/3"}]';;]],
      [[  *pipelines*) echo '[{"id":9,"status":"running","web_url":"https://g/p/9"}]';;]],
      'esac',
    })
    local remote =
      { kind = 'gitlab', host = 'gitlab.com', slug = 'g/p', name = 'origin' }
    local reviews, pipeline
    project.reviews(remote, function(...) reviews = { ... } end)
    project.pipeline(remote, 'main', function(...) pipeline = { ... } end)
    assert.is_true(
      vim.wait(5000, function() return reviews and pipeline end, 10)
    )
    assert.equals('1 open on g/p', reviews[2])
    assert.same({ text = '!3 Add x', url = 'https://g/mr/3' }, reviews[3][1])
    assert.same(
      { text = '● running #9', url = 'https://g/p/9' },
      pipeline[3][1]
    )
  end)

  it('lists open requests and the last pipeline on Azure DevOps', function()
    cli('az', {
      'case "$*" in',
      [[  *"--resource pullRequests"*) echo '{"count":1,"value":[{"pullRequestId":4,"title":"Add y"}]}';;]],
      -- The project's runs come together: the repository's is picked out
      [[  *"--resource builds"*) echo '{"count":2,"value":[{"id":1,"status":"completed","result":"succeeded","repository":{"name":"other"}},{"id":2,"status":"inProgress","definition":{"name":"web-ci"},"repository":{"name":"Web"},"_links":{"web":{"href":"https://dev.azure.com/c/2"}}}]}';;]],
      'esac',
    })
    local remote = {
      kind = 'azure',
      host = 'dev.azure.com',
      slug = 'c/My Project/web',
      name = 'origin',
      org = 'c',
      project = 'My Project',
      repo = 'web',
    }
    local reviews, pipeline
    project.reviews(remote, function(...) reviews = { ... } end)
    project.pipeline(remote, 'main', function(...) pipeline = { ... } end)
    assert.is_true(
      vim.wait(5000, function() return reviews and pipeline end, 10)
    )
    assert.equals('1 open on c/My Project/web', reviews[2])
    assert.same({
      text = '!4 Add y',
      url = 'https://dev.azure.com/c/My%20Project/_git/web/pullrequest/4',
    }, reviews[3][1])
    assert.same(
      { text = '● running web-ci', url = 'https://dev.azure.com/c/2' },
      pipeline[3][1]
    )
  end)

  it('says there are more requests than it lists', function()
    project.LIMIT = 2
    cli('gh', { [[echo '[{"number":1},{"number":2},{"number":3}]']] })
    local got
    project.reviews(
      { kind = 'github', host = 'github.com', slug = 'o/r' },
      function(...) got = { ... } end
    )
    assert.is_true(vim.wait(5000, function() return got ~= nil end, 10))
    assert.equals('2+ open on o/r', got[2])
  end)

  it('tells a Jira that failed from one with nothing assigned', function()
    cli('jira', { 'exit 1' })
    local jira = require('tools.jira')
    local restore = h.stub(
      jira,
      'run',
      function(_, on_done) on_done(false, {}, 'not logged in') end
    )
    local notes = {}
    local restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    local got
    project.jira(function(...) got = { ... } end)
    restore_notify()
    restore()
    assert.same({ 'failed', 'not logged in' }, { got[1], got[2] })
    -- The page says it, no toast on top
    assert.same({}, notes)
  end)

  it('says why a section is empty', function()
    local got = {}
    local function into(key)
      return function(state, note) got[key] = state .. ': ' .. note end
    end
    project.reviews(nil, into('reviews'))
    project.pipeline({ kind = 'github' }, nil, into('pipeline'))
    project.jira(into('jira'))
    assert.same({
      reviews = 'skipped: no GitHub, GitLab or Azure DevOps remote',
      pipeline = 'skipped: not on a branch',
      jira = 'skipped: the jira CLI is not installed',
    }, got)

    cli('gh', { 'echo "HTTP 401" >&2', 'exit 1' })
    local failed
    project.reviews(
      { kind = 'github', host = 'github.com', slug = 'o/r' },
      function(...) failed = { ... } end
    )
    assert.is_true(vim.wait(5000, function() return failed ~= nil end, 10))
    assert.same({ 'failed', 'HTTP 401' }, { failed[1], failed[2] })
  end)

  it('opens a page that fills in, and opens the file of a line', function()
    git('init', '-q', '-b', 'main')
    h.write(dir .. '/a.txt', { 'a' })
    vim.cmd.edit(dir .. '/a.txt')
    local bufnr = project.open()
    assert.equals('dyproject', vim.bo[bufnr].filetype)
    assert.is_true(vim.wait(5000, function()
      local text =
        table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
      return text:find('main, 0 ahead', 1, true) ~= nil
        and not text:find('…\n')
    end, 20))
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local row = vim.fn.index(lines, '  ?? a.txt') + 1
    assert.is_true(row > 0)
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    project.activate(bufnr)
    assert.equals(dir .. '/a.txt', vim.api.nvim_buf_get_name(0))
  end)
end)
