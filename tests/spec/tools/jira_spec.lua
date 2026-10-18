local h = require('helpers')

describe('tools.jira', function()
  local jira, notes, restore_notify

  before_each(function()
    h.unload('tools.jira')
    jira = require('tools.jira')
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    )
  end)
  after_each(function()
    restore_notify()
    vim.cmd('silent! %bwipeout!')
  end)

  it(
    'reads the plain listing of jira-cli',
    function()
      assert.same(
        {
          {
            key = 'OPS-12',
            type = 'Bug',
            status = 'In Progress',
            summary = 'Login fails\twith SSO',
          },
          {
            key = 'DEV_X-7',
            type = 'Task',
            status = 'To Do',
            summary = 'Write docs',
          },
        },
        jira.parse({
          'OPS-12\tBug\tIn Progress\tLogin fails\twith SSO',
          'DEV_X-7\t\tTask\tTo Do\tWrite docs  ',
          'not a key\tTask\tTo Do\tnothing',
          '',
        })
      )
    end
  )

  describe('branch names', function()
    it('slugs a summary into lowercase ASCII words', function()
      assert.equals(
        'fix-oauth2-login-sso-broken',
        jira.slug('Fix: OAuth2 login (SSO) — broken!')
      )
      assert.equals('sua-loi-dang-nhap', jira.slug('Sửa lỗi đăng nhập'))
      assert.equals('', jira.slug('  !! '))
    end)

    it('drops accents the same way whatever iconv the system has', function()
      assert.equals('cafe-creme-ubung', jira.slug('Café Crème Übung'))
      assert.equals(
        'duong-uu-tien-o-cua-so',
        jira.slug('ĐƯỜNG ưu tiên ở cửa sổ')
      )
      assert.equals('strasse-aeon', jira.slug('Straße Æon'))
    end)

    it('cuts a long summary between words', function()
      local slug = jira.slug(
        'Rotate the database credentials of every service in the staging cluster'
      )
      assert.equals('rotate-the-database-credentials-of', slug)
      assert.is_true(#slug <= 40)
    end)

    it('prefixes a branch by the type of its issue', function()
      assert.equals(
        'fix/OPS-12-login-fails',
        jira.branch_name({
          key = 'OPS-12',
          type = 'Bug',
          status = '',
          summary = 'Login fails',
        })
      )
      assert.equals(
        'feat/OPS-13-add-sso',
        jira.branch_name({
          key = 'OPS-13',
          type = 'Story',
          status = '',
          summary = 'Add SSO',
        })
      )
      assert.equals(
        'feat/OPS-14',
        jira.branch_name({
          key = 'OPS-14',
          type = 'Task',
          status = '',
          summary = '',
        })
      )
    end)

    it('finds the issue a branch is named after', function()
      assert.equals('OPS-12', jira.key_of('fix/OPS-12-login-fails'))
      assert.equals('DEV_X-7', jira.key_of('DEV_X-7'))
      assert.is_nil(jira.key_of('main'))
      assert.is_nil(jira.key_of('fix/ops-12-lowercase'))
      assert.is_nil(jira.key_of('fix/CVE-2024-3094-xz'))
      assert.is_nil(jira.key_of('feat/myABC-1'))
      assert.equals('OPS-12', jira.key_of('OPS-12-login'))
    end)
  end)

  it('gives up on a jira that never answers', function()
    local dir, cleanup = h.tmpdir()
    -- `exec`, so the timeout kills the process holding the pipes open
    h.write(dir .. '/jira', { '#!/bin/sh', 'exec sleep 30' })
    vim.fn.setfperm(dir .. '/jira', 'rwxr-xr-x')
    -- Not `h.stub`: `vim.env` is a proxy, and `rawget` reads nothing off it
    local path = vim.env.PATH
    vim.env.PATH = dir .. ':' .. path
    jira.RUN_TIMEOUT = 200
    local answer
    jira.run({ 'me' }, function(ok, _, err) answer = { ok, err } end)
    vim.wait(5000, function() return answer ~= nil end, 20)
    vim.env.PATH = path
    cleanup()
    assert.same({ false, 'jira gave no answer within 0.2 seconds' }, answer)
  end)

  it('says when jira-cli is not installed', function()
    local restore = h.stub(vim.fn, 'executable', function() return 0 end)
    local answer
    jira.run({ 'me' }, function(ok, lines, err) answer = { ok, lines, err } end)
    restore()
    assert.is_false(answer[1])
    assert.same({}, answer[2])
    assert.is_truthy(answer[3]:find('^jira%-cli is not installed'))
  end)

  describe('with jira faked', function()
    local answer, calls, restore_run

    before_each(function()
      answer, calls = { true, {}, '' }, {}
      restore_run = h.stub(jira, 'run', function(args, on_done)
        table.insert(calls, args)
        on_done(unpack(answer, 1, 3))
      end)
    end)
    after_each(function() restore_run() end)

    it('says why listing failed, unless told to be quiet', function()
      answer = { false, {}, 'not logged in' }
      local got
      jira.list('x', function(...) got = { ... } end)
      assert.same({ {}, 'not logged in' }, got)
      assert.equals('Listing issues failed: not logged in', notes[1].msg)
      jira.list('x', function(...) got = { ... } end, { quiet = true })
      assert.equals(1, #notes)
    end)

    it('reports a failure with no reason as one', function()
      answer = { false, {}, '' }
      jira.open('OPS-1')
      assert.same({ 'open', 'OPS-1' }, calls[1])
      assert.same(
        { msg = 'jira failed', level = vim.log.levels.ERROR },
        notes[1]
      )
    end)

    it('views an issue in a split, or says why it cannot', function()
      answer = { true, { '# OPS-1', 'Fix it' }, '' }
      jira.view('OPS-1')
      assert.equals('markdown', vim.bo.filetype)
      assert.same(
        { '# OPS-1', 'Fix it' },
        vim.api.nvim_buf_get_lines(0, 0, -1, false)
      )
      answer = { false, {}, 'no such issue' }
      jira.view('OPS-2')
      assert.same(
        { msg = 'no such issue', level = vim.log.levels.ERROR },
        notes[1]
      )
    end)

    it('copies or inserts the key, or asks what to do', function()
      local issue =
        { key = 'OPS-1', type = '', status = '', summary = 'Fix it' }
      jira.act('copy', issue)
      assert.equals('Copied OPS-1', notes[1].msg)
      local offered
      local restore = h.stub(vim.ui, 'select', function(items, opts, choose)
        offered = { opts.prompt, vim.tbl_map(opts.format_item, items) }
        choose(nil)
      end)
      jira.menu(issue)
      restore()
      assert.same({
        'OPS-1 Fix it',
        vim.tbl_map(function(a) return a[2] end, jira.ACTIONS),
      }, offered)
      restore = h.stub(
        vim.ui,
        'select',
        function(items, _, choose) choose(items[6]) end
      )
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'fix: ' } }))
      vim.api.nvim_win_set_cursor(0, { 1, 4 })
      jira.menu(issue)
      restore()
      assert.equals('fix: OPS-1', vim.api.nvim_get_current_line())
    end)

    it('refuses to start a second branch for the branch checked out', function()
      local restore = h.stub(
        jira,
        'current_key',
        function(on_done) on_done('OPS-12') end
      )
      jira.command({ fargs = { 'branch' } })
      restore()
      assert.same({}, calls)
      assert.equals('Already on a branch of OPS-12', notes[1].msg)
    end)

    it('asks for the JQL of a search given none', function()
      local picked
      local restore_pick = h.stub(
        jira,
        'pick',
        function(opts) picked = opts end
      )
      local restore = h.stub(
        vim.ui,
        'input',
        function(_, on_confirm) on_confirm(' ') end
      )
      jira.command({ fargs = { 'search' } })
      assert.is_nil(picked)
      restore()
      restore = h.stub(
        vim.ui,
        'input',
        function(_, on_confirm) on_confirm('project = OPS') end
      )
      jira.command({ fargs = { 'search' } })
      restore()
      restore_pick()
      assert.same({ jql = 'project = OPS', title = 'Jira search' }, picked)
    end)

    describe('pick', function()
      local picked, previewed, closed, restore_snacks

      before_each(function()
        picked, previewed, closed = nil, nil, 0
        restore_snacks = h.stub(_G, 'Snacks', {
          picker = {
            pick = function(opts) picked = opts end,
            preview = { cmd = function(cmd) previewed = cmd end },
          },
        })
        answer = {
          true,
          { 'OPS-1\tBug\tTo Do\tFix it', 'OPS-123\tTask\tDone\tLonger key' },
          '',
        }
      end)
      after_each(function() restore_snacks() end)

      local picker = {
        close = function() closed = closed + 1 end,
      }

      it('says when no issue matches', function()
        answer = { true, {}, '' }
        jira.pick()
        assert.is_nil(picked)
        assert.equals('No issues match ' .. jira.DEFAULT_JQL, notes[1].msg)
      end)

      it('offers the issues, keys lined up, with a preview', function()
        jira.pick({ title = 'Mine' })
        assert.equals('Mine', picked.title)
        assert.equals('OPS-1 To Do Fix it', picked.items[1].text)
        local line = picked.format(picked.items[1])
        assert.same({ 'OPS-1  ', 'SnacksPickerLabel' }, line[1])
        assert.equals('To Do', line[3][1])
        picked.preview({ item = picked.items[2] })
        assert.same(
          { 'jira', 'issue', 'view', 'OPS-123', '--plain' },
          previewed
        )
      end)

      it(
        'does the action asked, or asks for one, on the issue confirmed',
        function()
          local acted = {}
          local restore = h.stub(
            jira,
            'act',
            function(action, item) table.insert(acted, { action, item.key }) end
          )
          local menued
          local restore_menu = h.stub(
            jira,
            'menu',
            function(item) menued = item.key end
          )
          jira.pick({ action = 'open' })
          picked.confirm(picker, nil)
          picked.confirm(picker, picked.items[1])
          jira.pick()
          picked.confirm(picker, picked.items[2])
          picked.actions.jira_branch(picker, picked.items[1])
          picked.actions.jira_open(picker, nil)
          picked.actions.jira_insert(picker, picked.items[2])
          restore_menu()
          restore()
          assert.equals(6, closed)
          assert.same({
            { 'open', 'OPS-1' },
            { 'branch', 'OPS-1' },
            { 'insert', 'OPS-123' },
          }, acted)
          assert.equals('OPS-123', menued)
          assert.equals('Start a branch', picked.win.input.keys['<C-b>'].desc)
        end
      )
    end)
  end)

  describe('commands', function()
    local calls, restore_run

    before_each(function()
      calls = {}
      restore_run = h.stub(jira, 'run', function(args, on_done)
        table.insert(calls, args)
        on_done(true, {}, '')
      end)
    end)
    after_each(function() restore_run() end)

    --- Answer every `vim.ui.input` in turn with `answers`
    local function answering(answers)
      local index = 0
      return h.stub(vim.ui, 'input', function(_, on_confirm)
        index = index + 1
        on_confirm(answers[index])
      end)
    end

    it('logs work with a comment, or without one', function()
      local restore = answering({ '1h 30m', 'review' })
      jira.worklog('OPS-12')
      restore()
      restore = answering({ '2h', '' })
      jira.worklog('OPS-12')
      restore()
      assert.same({
        {
          'issue',
          'worklog',
          'add',
          'OPS-12',
          '1h 30m',
          '--no-input',
          '--comment',
          'review',
        },
        { 'issue', 'worklog', 'add', 'OPS-12', '2h', '--no-input' },
      }, calls)
      assert.equals('Logged 2h on OPS-12', notes[#notes].msg)
    end)

    it('logs nothing when the time is not given', function()
      local restore = answering({ nil })
      jira.worklog('OPS-12')
      restore()
      assert.same({}, calls)
    end)

    it('moves an issue to the state typed', function()
      local restore = answering({ 'Done' })
      jira.move('OPS-12')
      restore()
      assert.same({ { 'issue', 'move', 'OPS-12', 'Done' } }, calls)
    end)

    it('acts on the issue of the branch, or asks for one', function()
      local restore_key = h.stub(
        jira,
        'current_key',
        function(on_done) on_done('OPS-12') end
      )
      jira.command({ fargs = { 'open' } })
      restore_key()
      assert.same({ { 'open', 'OPS-12' } }, calls)

      local picked
      restore_key = h.stub(
        jira,
        'current_key',
        function(on_done) on_done(nil) end
      )
      local restore_pick = h.stub(
        jira,
        'pick',
        function(opts) picked = opts end
      )
      jira.command({ fargs = { 'worklog' } })
      restore_pick()
      restore_key()
      assert.equals('worklog', picked.action)
    end)

    it('takes the key given on the command line over the branch', function()
      local restore_key = h.stub(
        jira,
        'current_key',
        function(on_done) on_done('OPS-12') end
      )
      jira.command({ fargs = { 'open', 'OPS-99' } })
      restore_key()
      assert.same({ { 'open', 'OPS-99' } }, calls)
    end)

    it('searches by the JQL given', function()
      local picked
      local restore_pick = h.stub(
        jira,
        'pick',
        function(opts) picked = opts end
      )
      jira.command({ fargs = { 'search', 'project', '=', 'OPS' } })
      restore_pick()
      assert.equals('project = OPS', picked.jql)
    end)

    it('turns down a subcommand it does not know', function()
      jira.command({ fargs = { 'nope' } })
      assert.equals('Unknown subcommand: nope', notes[1].msg)
      assert.equals(vim.log.levels.ERROR, notes[1].level)
    end)
  end)

  describe('branch', function()
    local dir, cleanup, restore_cwd

    local function git(args)
      local result = vim
        .system(vim.list_extend({ 'git', '-C', dir }, args), {
          text = true,
          env = {
            GIT_AUTHOR_NAME = 'Spec',
            GIT_AUTHOR_EMAIL = 'spec@example.com',
            GIT_COMMITTER_NAME = 'Spec',
            GIT_COMMITTER_EMAIL = 'spec@example.com',
          },
        })
        :wait(10000)
      assert.equals(0, result.code, result.stderr)
      return vim.trim(result.stdout or '')
    end

    before_each(function()
      dir, cleanup = h.tmpdir()
      git({ 'init', '--initial-branch=main', '--quiet' })
      git({ 'commit', '--quiet', '--allow-empty', '-m', 'start' })
      local previous = vim.uv.cwd()
      vim.cmd.cd(dir)
      restore_cwd = function() vim.cmd.cd(previous) end
    end)
    after_each(function()
      restore_cwd()
      cleanup()
    end)

    it('starts a branch for an issue, then switches back to it', function()
      local restore = h.stub(
        vim.ui,
        'input',
        function(opts, on_confirm) on_confirm(opts.default) end
      )
      local issue =
        { key = 'OPS-12', type = 'Bug', status = '', summary = 'Login fails' }
      jira.branch(issue)
      -- The switch runs in the background
      vim.wait(5000, function() return #notes > 0 end)
      assert.equals(
        'fix/OPS-12-login-fails',
        git({ 'branch', '--show-current' })
      )
      -- Read off the main loop
      local key = false
      jira.current_key(function(found) key = found end)
      assert.is_false(key)
      assert.is_true(vim.wait(5000, function() return key ~= false end))
      assert.equals('OPS-12', key)

      git({ 'switch', '--quiet', 'main' })
      local before = #notes
      jira.branch(issue)
      vim.wait(5000, function() return #notes > before end)
      restore()
      assert.equals(
        'fix/OPS-12-login-fails',
        git({ 'branch', '--show-current' })
      )
      assert.equals('Switched to fix/OPS-12-login-fails', notes[#notes].msg)
    end)

    it('says why git could not switch', function()
      local real = vim.fn.exepath('git')
      local bin = dir .. '/bin'
      h.write(bin .. '/git', {
        '#!/bin/sh',
        'if [ "$3" = switch ]; then echo "hook failed" >&2; exit 1; fi',
        'exec "' .. real .. '" "$@"',
      })
      vim.fn.setfperm(bin .. '/git', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = bin .. ':' .. path
      local restore = h.stub(
        vim.ui,
        'input',
        function(_, on_confirm) on_confirm('fix/x') end
      )
      jira.branch({ key = 'OPS-1', type = 'Bug', status = '', summary = 'x' })
      local done = vim.wait(10000, function() return #notes > 0 end)
      vim.env.PATH = path
      restore()
      assert.is_true(done)
      assert.same(
        { msg = 'hook failed', level = vim.log.levels.ERROR },
        notes[1]
      )
    end)

    it('stops a switch that hangs, and says so', function()
      local real = vim.fn.exepath('git')
      local bin = dir .. '/bin'
      h.write(bin .. '/git', {
        '#!/bin/sh',
        'if [ "$3" = switch ]; then exec sleep 30; fi',
        'exec "' .. real .. '" "$@"',
      })
      vim.fn.setfperm(bin .. '/git', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = bin .. ':' .. path
      local restores = {
        h.stub(jira, 'SWITCH_TIMEOUT', 300),
        h.stub(
          vim.ui,
          'input',
          function(_, on_confirm) on_confirm('fix/hang') end
        ),
      }
      jira.branch({ key = 'OPS-1', type = 'Bug', status = '', summary = 'x' })
      local done = vim.wait(10000, function() return #notes > 0 end)
      vim.env.PATH = path
      for _, restore in ipairs(restores) do
        restore()
      end
      assert.is_true(done)
      assert.equals(
        'git switch fix/hang gave no answer in 0 min and was stopped',
        notes[1].msg
      )
    end)
  end)
end)
