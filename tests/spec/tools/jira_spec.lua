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
  end)
end)
