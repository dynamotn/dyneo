local h = require('helpers')

-- 2026-10-20T10:00:00Z, and the incident window around it
local T = 1792490400

describe('tools.postmortem', function()
  local postmortem, dir, cleanup, path, notes, restore_notify

  before_each(function()
    h.unload('tools.postmortem')
    postmortem = require('tools.postmortem')
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
  end)
  after_each(function()
    vim.env.PATH = path
    restore_notify()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('reads a local time, a date with it or today', function()
    local now = os.time({ year = 2026, month = 10, day = 20, hour = 15 })
    assert.equals(
      os.time({ year = 2026, month = 10, day = 20, hour = 13, min = 5, sec = 0 }),
      postmortem.parse_time('13:05', now)
    )
    assert.equals(
      os.time({ year = 2026, month = 9, day = 1, hour = 7, min = 0, sec = 0 }),
      postmortem.parse_time('2026-09-01 07:00')
    )
    for _, text in ipairs({ 'noon', '25:00', '2026-13-01 10:00', '12:60' }) do
      assert.is_nil(postmortem.parse_time(text), text)
    end
  end)

  it('writes the timeline in order, a table cell to a line', function()
    local lines = postmortem.template(3, '2026-10-20', 'API down', T - 600, T, {
      { time = T, source = 'kubernetes', text = 'a | b\nc' },
      { time = T - 300, source = 'git', text = '`abc` deploy' },
    }, { 'kubernetes, kubectl is not installed' })
    local text = table.concat(lines, '\n')
    assert.equals('# 3. Postmortem: API down', lines[1])
    assert.is_truthy(
      text:find('From 2026-10-20 09:50:00 to 2026-10-20 10:00:00 UTC', 1, true)
    )
    local first =
      text:find('| 2026-10-20 09:55:00 | git | `abc` deploy |', 1, true)
    local second =
      text:find('| 2026-10-20 10:00:00 | kubernetes | a \\| b c |', 1, true)
    assert.is_truthy(first and second and first < second)
    assert.is_truthy(
      text:find('- Not read: kubernetes, kubectl is not installed', 1, true)
    )
    assert.is_truthy(text:find('## Action items\n\n- [ ]', 1, true))
  end)

  --- Make a commit in the repository at `dir`, dated `time`
  local function commit(time, subject)
    local date = ('@%d +0000'):format(time)
    local result = require('util.system').sync({
      'git',
      '-c',
      'user.name=Tester',
      '-c',
      'user.email=t@example.com',
      '-c',
      'commit.gpgsign=false',
      'commit',
      '--allow-empty',
      '-q',
      '-m',
      subject,
    }, {
      cwd = dir,
      env = { GIT_AUTHOR_DATE = date, GIT_COMMITTER_DATE = date },
      timeout = 10000,
    })
    assert.equals(0, result.code, result.stderr)
  end

  it('writes a record of the window, from git and the cluster', function()
    require('util.system').sync({ 'git', 'init', '-q' }, { cwd = dir })
    commit(T - 7200, 'before the window')
    commit(T - 300, 'raise the pool size')
    commit(T + 7200, 'after the window')
    h.write(dir .. '/events.json', {
      vim.json.encode({
        items = {
          {
            type = 'Warning',
            reason = 'BackOff',
            message = 'Back-off restarting',
            lastTimestamp = '2026-10-20T09:58:00Z',
            involvedObject = {
              kind = 'Pod',
              name = 'api-1',
              namespace = 'prod',
            },
          },
          {
            type = 'Normal',
            reason = 'Pulled',
            lastTimestamp = '2026-10-19T00:00:00Z',
            involvedObject = { kind = 'Pod', name = 'old' },
          },
        },
      }),
    })
    h.write(dir .. '/bin/kubectl', {
      '#!/bin/sh',
      'cat "' .. dir .. '/events.json"',
    })
    vim.fn.setfperm(dir .. '/bin/kubectl', 'rwxr-xr-x')
    h.write(dir .. '/README.md', { '# app' })
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/README.md'))
    local file
    local done = false
    postmortem.write('API down', T - 600, T + 600, function(f)
      file, done = f, true
    end)
    assert.is_true(vim.wait(10000, function() return done end, 10))
    assert.equals(dir .. '/docs/adr/0001-postmortem-api-down.md', file)
    local text = table.concat(vim.fn.readfile(file), '\n')
    assert.is_truthy(text:find('raise the pool size (Tester)', 1, true))
    assert.is_falsy(text:find('before the window', 1, true))
    assert.is_falsy(text:find('after the window', 1, true))
    assert.is_truthy(
      text:find(
        '**Warning** prod/Pod/api-1 BackOff: Back-off restarting',
        1,
        true
      )
    )
    assert.is_falsy(text:find('Pulled', 1, true))
    assert.equals(file, vim.api.nvim_buf_get_name(0))
    assert.equals('Postmortem 1 written, 2 timeline entries', notes[#notes])
  end)

  it('names a source it could not read, and still writes', function()
    -- A repository with no commit: its root is this folder, never the
    -- working directory, and `git log` has nothing to read
    require('util.system').sync({ 'git', 'init', '-q' }, { cwd = dir })
    h.write(dir .. '/notes.md', {})
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
    local file
    postmortem.write('Outage', T - 600, T, function(f) file = f or false end)
    assert.is_true(vim.wait(10000, function() return file ~= nil end, 10))
    local text = table.concat(vim.fn.readfile(file), '\n')
    assert.is_truthy(text:find('- Not read: git, ', 1, true))
    assert.is_truthy(
      text:find('- Not read: kubernetes, kubectl is not installed', 1, true)
    )
    assert.is_truthy(notes[#notes]:find('; not read: git', 1, true))
  end)

  it('lists the action items still open', function()
    h.write(dir .. '/docs/adr/0001-postmortem-x.md', {
      '# 1. Postmortem: x',
      '',
      '## Action items',
      '',
      '- [x] Add an alert',
      '- [ ] Raise the limit',
    })
    vim.fn.mkdir(dir .. '/.git', 'p')
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/docs/adr/0001-postmortem-x.md'))
    postmortem.command({ fargs = {} })
    local items = vim.fn.getqflist()
    assert.equals(1, #items)
    assert.equals('Action items: Raise the limit', items[1].text)
    vim.cmd('cclose')
  end)
end)
