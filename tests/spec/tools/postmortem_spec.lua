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
    -- Only git on the path: a CI runner ships kubectl in /usr/bin
    vim.uv.fs_symlink(vim.fn.exepath('git'), dir .. '/bin/git')
    vim.env.PATH = dir .. '/bin'
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

  --- Put a `kubectl` on the path that prints `lines` and exits with `code`
  local function kubectl(lines, code)
    h.write(
      dir .. '/bin/kubectl',
      vim.list_extend(
        { '#!/bin/sh' },
        vim.list_extend(lines, {
          'exit ' .. (code or 0),
        })
      )
    )
    vim.fn.setfperm(dir .. '/bin/kubectl', 'rwxr-xr-x')
  end

  --- What `postmortem.kube` hands back for the window around `T`
  local function kube()
    local result
    postmortem.kube(
      T - 600,
      T + 600,
      function(entries, err) result = { entries = entries, err = err } end
    )
    assert.is_true(vim.wait(10000, function() return result ~= nil end, 10))
    return result
  end

  it('says why kubectl failed', function()
    kubectl({ 'echo "Unable to connect to the server" >&2' }, 1)
    local result = kube()
    assert.is_nil(result.entries)
    assert.equals('Unable to connect to the server', result.err)
  end)

  it('says when kubectl answers with something not JSON', function()
    kubectl({ 'echo "No resources found"' })
    local result = kube()
    assert.is_nil(result.entries)
    assert.equals('kubectl answered with something not JSON', result.err)
  end)

  it(
    'keeps the warnings first when the cluster has more than it keeps',
    function()
      h.write(dir .. '/events.json', {
        vim.json.encode({
          items = {
            {
              type = 'Normal',
              reason = 'Scheduled',
              firstTimestamp = '2026-10-20T09:55:00Z',
              metadata = { namespace = 'prod' },
            },
            {
              type = 'Normal',
              reason = 'Pulled',
              eventTime = '2026-10-20T09:56:00Z',
              involvedObject = { kind = 'Pod', name = 'api-2' },
            },
            {
              type = 'Warning',
              reason = 'BackOff',
              lastTimestamp = '2026-10-20T09:58:00Z',
              involvedObject = { kind = 'Pod', name = 'api-1' },
            },
          },
        }),
      })
      kubectl({ 'exec /bin/cat "' .. dir .. '/events.json"' })
      local restore = h.stub(postmortem, 'MAX_ENTRIES', 2)
      local result = kube()
      restore()
      assert.is_nil(result.err)
      assert.same({
        '**Warning** -/Pod/api-1 BackOff: ',
        'prod/?/? Scheduled: ',
      }, vim.tbl_map(
        function(entry) return entry.text end,
        result.entries
      ))
    end
  )

  it('says a source was read only up to what it keeps', function()
    h.write(dir .. '/events.json', {
      vim.json.encode({
        items = {
          { reason = 'A', lastTimestamp = '2026-10-20T09:55:00Z' },
          { reason = 'B', lastTimestamp = '2026-10-20T09:56:00Z' },
        },
      }),
    })
    kubectl({ 'exec /bin/cat "' .. dir .. '/events.json"' })
    -- No git: only the cluster is read
    vim.env.PATH = dir .. '/bin'
    local restore = h.stub(postmortem, 'MAX_ENTRIES', 1)
    vim.fn.mkdir(dir .. '/.git', 'p')
    h.write(dir .. '/notes.md', {})
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
    local file
    postmortem.write(
      'Outage',
      T - 600,
      T + 600,
      function(f) file = f or false end
    )
    assert.is_true(vim.wait(10000, function() return file ~= nil end, 10))
    restore()
    local text = table.concat(vim.fn.readfile(file), '\n')
    assert.is_truthy(text:find('-/?/? A: ', 1, true))
    assert.is_falsy(text:find('-/?/? B: ', 1, true))
    assert.is_truthy(
      text:find('- Not read: kubernetes past the first 1 entries', 1, true)
    )
  end)

  it('writes nothing when the records point outside the project', function()
    local outside, clean_outside = h.tmpdir()
    h.write(dir .. '/.adr-dir', { '../' .. vim.fs.basename(outside) })
    h.write(dir .. '/notes.md', {})
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
    local file
    postmortem.write('Outage', T - 600, T, function(f) file = f or false end)
    clean_outside()
    assert.is_false(file)
    assert.equals(
      '`.adr-dir` points outside the project: ../' .. vim.fs.basename(outside),
      notes[#notes]
    )
  end)

  it('writes nothing over what is at the name of the record', function()
    vim.env.PATH = dir .. '/bin'
    vim.fn.mkdir(dir .. '/.git', 'p')
    -- A folder is no record: the next number is still 1, and its name taken
    local taken = dir .. '/docs/adr/0001-postmortem-outage.md'
    vim.fn.mkdir(taken, 'p')
    h.write(dir .. '/notes.md', {})
    vim.cmd.edit(vim.fn.fnameescape(dir .. '/notes.md'))
    local file
    postmortem.write('Outage', T - 600, T, function(f) file = f or false end)
    assert.is_true(vim.wait(10000, function() return file ~= nil end, 10))
    assert.is_false(file)
    assert.equals(taken .. ' is there already, and is no record', notes[#notes])
    assert.equals(1, vim.fn.isdirectory(taken))
    assert.equals(dir .. '/notes.md', vim.api.nvim_buf_get_name(0))
  end)

  describe('asking for the window', function()
    local prompts, written, restores

    --- Answer the prompts with `answers` in turn; `false` stands for a
    --- prompt left with <Esc>
    local function answer(answers)
      local index = 0
      table.insert(
        restores,
        h.stub(vim.ui, 'input', function(opts, on_confirm)
          index = index + 1
          table.insert(prompts, opts.prompt)
          local reply = answers[index]
          if reply == false then reply = nil end
          on_confirm(reply)
        end)
      )
    end

    before_each(function()
      prompts, written, restores = {}, {}, {}
      table.insert(
        restores,
        h.stub(
          postmortem,
          'write',
          function(title, since, till)
            table.insert(written, { title, since, till })
          end
        )
      )
    end)
    after_each(function()
      for _, restore in ipairs(restores) do
        restore()
      end
    end)

    local start = '2026-10-20 09:00'
    local since = os.time({
      year = 2026,
      month = 10,
      day = 20,
      hour = 9,
      min = 0,
      sec = 0,
    })

    it('writes the window it is given', function()
      answer({ start, '2026-10-20 10:00' })
      postmortem.new('API down')
      assert.same({ { 'API down', since, since + 3600 } }, written)
      assert.same({
        'Started (YYYY-MM-DD HH:MM, or HH:MM today): ',
        'Ended (empty for now): ',
      }, prompts)
    end)

    it('ends the window now when no end is given', function()
      answer({ start, '  ' })
      local before = os.time()
      postmortem.new('API down')
      assert.equals(1, #written)
      assert.is_true(written[1][3] >= before)
    end)

    it('asks what happened when no title is given', function()
      answer({ '  API down  ', start, '2026-10-20 10:00' })
      postmortem.new()
      assert.equals('What happened: ', prompts[1])
      assert.equals('API down', written[1][1])
    end)

    it('stops when what happened is left empty', function()
      answer({ ' ' })
      postmortem.new('')
      assert.same({ 'What happened: ' }, prompts)
      assert.same({}, written)
    end)

    it('stops when no start is given', function()
      answer({ '' })
      postmortem.new('API down')
      assert.same({}, written)
      assert.same({}, notes)
    end)

    it('stops when the end is left with escape', function()
      answer({ start, false })
      postmortem.new('API down')
      assert.same({}, written)
      assert.same({}, notes)
    end)

    it('refuses what is not a time', function()
      answer({ 'noon' })
      postmortem.new('API down')
      assert.equals('Not a time: noon', notes[#notes])
      answer({ start, 'later' })
      postmortem.new('API down')
      assert.equals('Not a time: later', notes[#notes])
      assert.same({}, written)
    end)

    it('refuses a window that ends before it starts', function()
      answer({ start, '2026-10-20 08:00' })
      postmortem.new('API down')
      assert.equals('It ended before it started', notes[#notes])
      assert.same({}, written)
    end)

    it('takes the title from the words after new', function()
      answer({ start, '2026-10-20 10:00' })
      postmortem.command({ fargs = { 'new', 'API', 'down' } })
      assert.equals('API down', written[1][1])
    end)
  end)

  it('refuses an unknown subcommand', function()
    postmortem.command({ fargs = { 'old' } })
    assert.equals('Unknown subcommand: old', notes[#notes])
  end)
end)
