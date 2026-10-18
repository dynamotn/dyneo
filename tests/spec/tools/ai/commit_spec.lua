local h = require('helpers')

describe('tools.ai.commit', function()
  local commit, dir, cleanup, restores, notes, audit, path, repo

  --- A fake `name` on the private PATH running `body`
  local function fake(name, body)
    h.write(dir .. '/bin/' .. name, vim.list_extend({ '#!/bin/sh' }, body))
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function git(...)
    local result = vim
      .system(vim.list_extend({ 'git', '-C', repo }, { ... }), { text = true })
      :wait()
    assert.equals(0, result.code, result.stderr)
  end

  --- A commit message buffer of `repo`, as `git commit` opens it
  local function message_buffer(lines)
    local bufnr = h.buffer({
      name = repo .. '/.git/COMMIT_EDITMSG',
      lines = lines or { '', '# Please enter the commit message' },
    })
    vim.bo[bufnr].filetype = 'gitcommit'
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  local function wait_for(fn, what)
    assert.is_true(vim.wait(5000, fn, 20), 'never ' .. what)
  end

  before_each(function()
    dir, cleanup = h.tmpdir()
    repo = dir .. '/repo'
    vim.fn.mkdir(repo, 'p')
    git('init', '-q')
    git('config', 'user.email', 'spec@example.com')
    git('config', 'user.name', 'Spec')
    h.write(repo .. '/a.txt', { 'one' })
    git('add', 'a.txt')
    git('commit', '-q', '-m', 'feat(a): add one')
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    fake('betterleaks', { 'cat > /dev/null', 'echo "[]"' })
    fake('claude', {
      'cat > "' .. dir .. '/sent"',
      'printf "\\`\\`\\`\\nfeat(a): add two\\n\\nBecause.\\n\\`\\`\\`\\n"',
    })
    notes, audit = {}, {}
    _G.DyNeo.ai = { commit_command = { 'claude', '-p' }, commit_timeout = 5000 }
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(package.loaded, 'util.ai_audit', {
        record = function(_, action, what, detail)
          table.insert(audit, { action, what, detail })
        end,
      }),
      h.stub(package.loaded, 'util.project_rtp', {
        current = function() return nil end,
      }),
    }
    h.unload(
      'tools.ai',
      'tools.ai.commit',
      'tools.ai.git',
      'tools.ai.check',
      'tools.ai.prompts',
      'util.ai_policy'
    )
    commit = require('tools.ai.commit')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    _G.DyNeo.ai = nil
    vim.env.PATH = path
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('writes the message of the staged diff into an empty message', function()
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('add', 'a.txt')
    local bufnr = message_buffer()
    commit.write()
    wait_for(
      function() return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= '' end,
      'wrote the message'
    )
    assert.same({
      'feat(a): add two',
      '',
      'Because.',
      '',
      '# Please enter the commit message',
    }, vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
    local sent = table.concat(vim.fn.readfile(dir .. '/sent'), '\n')
    assert.is_truthy(sent:find('+two', 1, true))
    assert.is_truthy(sent:find('feat(a): add one', 1, true))
    assert.equals('sent', audit[1][1])
    assert.equals(repo, audit[1][2])
  end)

  it('refuses when nothing is staged', function()
    message_buffer()
    commit.write()
    wait_for(function() return #notes > 0 end, 'said why')
    assert.equals('Nothing is staged', notes[1])
    assert.equals('refused', audit[1][1])
  end)

  it('refuses a staged file that is kept from AI', function()
    h.write(repo .. '/id_ed25519', { 'key' })
    git('add', 'id_ed25519')
    message_buffer()
    commit.write()
    wait_for(function() return #notes > 0 end, 'said why')
    assert.is_truthy(notes[1]:find('id_ed25519', 1, true))
    assert.is_false(vim.uv.fs_stat(dir .. '/sent') ~= nil)
  end)

  it('refuses what betterleaks finds, and a scan that fails', function()
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('add', 'a.txt')
    fake(
      'betterleaks',
      { 'cat > /dev/null', 'echo \'[{"RuleID":"x-token"}]\'' }
    )
    message_buffer()
    commit.write()
    wait_for(function() return #notes > 0 end, 'said why')
    assert.is_truthy(notes[1]:find('x-token', 1, true))

    fake('betterleaks', { 'cat > /dev/null', 'exit 2' })
    commit.write()
    wait_for(function() return #notes > 1 end, 'said why')
    assert.is_truthy(notes[2]:find('could not check', 1, true))
    assert.is_false(vim.uv.fs_stat(dir .. '/sent') ~= nil)
  end)

  it('says when the prompt is missing', function()
    message_buffer()
    local prompts = require('tools.ai.prompts')
    table.insert(
      restores,
      h.stub(prompts, 'template', function() return nil end)
    )
    commit.write()
    assert.is_truthy(notes[1]:find('No prompt ' .. commit.PROMPT, 1, true))
    assert.same({}, audit)
  end)

  it('refuses a message that is in no work tree', function()
    vim.fn.mkdir(dir .. '/loose', 'p')
    local bufnr = h.buffer({ name = dir .. '/loose/COMMIT_EDITMSG' })
    vim.bo[bufnr].filetype = 'gitcommit'
    vim.api.nvim_set_current_buf(bufnr)
    commit.write()
    wait_for(function() return #notes > 0 end, 'said why')
    assert.is_truthy(notes[1]:find('Not in a git work tree', 1, true))
    assert.same(
      { 'refused', dir .. '/loose/COMMIT_EDITMSG', 'commit' },
      audit[1]
    )
  end)

  it('says when the diff was cut', function()
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('add', 'a.txt')
    require('tools.ai.git').MAX_DIFF = 16
    local bufnr = message_buffer()
    commit.write()
    wait_for(
      function() return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= '' end,
      'wrote the message'
    )
    assert.is_truthy(notes[1]:find('The diff was cut at 0 KiB', 1, true))
    local sent = table.concat(vim.fn.readfile(dir .. '/sent'), '\n')
    assert.is_truthy(sent:find('(diff cut at 0 KiB)', 1, true))
  end)

  it('only runs in a commit message', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'x' } }))
    commit.write()
    assert.is_truthy(notes[1]:find('git commit', 1, true))
  end)

  it('says so when the command fails', function()
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('add', 'a.txt')
    fake('claude', { 'cat > /dev/null', 'echo "not signed in" >&2', 'exit 1' })
    local bufnr = message_buffer()
    commit.write()
    wait_for(
      function() return notes[#notes] == 'not signed in' end,
      'reported the failure'
    )
    assert.equals('', vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
  end)

  it('writes with the local command where AI stays local', function()
    h.write(repo .. '/.nvim/ai.json', { '{ "local_only": true }' })
    h.write(repo .. '/a.txt', { 'one', 'two' })
    git('add', 'a.txt')
    local bufnr = message_buffer()
    commit.write()
    wait_for(function() return #notes > 0 end, 'said why')
    assert.is_truthy(notes[1]:find('local_command', 1, true))
    assert.is_false(vim.uv.fs_stat(dir .. '/sent') ~= nil)

    DyNeo.ai.local_command = { 'claude', '--local' }
    commit.write()
    wait_for(
      function() return vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] ~= '' end,
      'wrote the message'
    )
    assert.equals(
      'feat(a): add two',
      vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1]
    )
  end)

  describe('comment prefix', function()
    it('takes the one git is set to, the last of its two names', function()
      local bufnr = message_buffer({ '', '; Please enter the commit message' })
      git('config', 'core.commentChar', ';')
      local prefix
      commit.comment(repo, bufnr, function(p) prefix = p end)
      wait_for(function() return prefix ~= nil end, 'read the setting')
      assert.equals(';', prefix)
      git('config', 'core.commentString', '//')
      prefix = nil
      commit.comment(repo, bufnr, function(p) prefix = p end)
      wait_for(function() return prefix ~= nil end, 'read the setting')
      assert.equals('//', prefix)
    end)

    it('finds the one git picked for auto in the lines it wrote', function()
      local bufnr = message_buffer({
        '',
        '# a heading of mine',
        '; ------------------------ >8 ------------------------',
        '; Do not modify or remove the line above.',
      })
      assert.equals(';', commit.prefix(bufnr, 'auto'))
      assert.equals(
        '%',
        commit.prefix(h.buffer({ lines = { '', '% On branch main' } }), nil)
      )
      assert.equals(
        '#',
        commit.prefix(h.buffer({ lines = { '', 'text' } }), nil)
      )
    end)

    it('ends the message at that prefix, not at a #', function()
      local bufnr = message_buffer({
        '',
        '# not a comment here',
        '; Please enter the commit message',
      })
      local asked = false
      table.insert(
        restores,
        h.stub(vim.ui, 'select', function(_, _, on_choice)
          asked = true
          on_choice('Keep mine')
        end)
      )
      commit.insert(bufnr, { 'subject' }, ';')
      -- `# not a comment here` was in the message area: asked first, kept
      assert.is_true(asked)
      assert.same(
        { '', '# not a comment here', '; Please enter the commit message' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
      local empty =
        h.buffer({ lines = { '', '; Please enter the commit message' } })
      commit.insert(empty, { 'subject' }, ';')
      assert.same(
        { 'subject', '', '; Please enter the commit message' },
        vim.api.nvim_buf_get_lines(empty, 0, -1, false)
      )
    end)
  end)

  describe('insert', function()
    it('asks before replacing a message already written', function()
      local bufnr = message_buffer({ 'mine', '# comment' })
      local choice = 'Keep mine'
      table.insert(
        restores,
        h.stub(
          vim.ui,
          'select',
          function(_, _, on_choice) on_choice(choice) end
        )
      )
      commit.insert(bufnr, { 'theirs' })
      assert.same(
        { 'mine', '# comment' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
      choice = 'Replace it'
      commit.insert(bufnr, { 'theirs' })
      assert.same(
        { 'theirs', '', '# comment' },
        vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      )
    end)
  end)

  it('fills the prompt and keeps percent signs of the diff', function()
    local text = commit.build(
      { body = '{convention}\n{history}\n{files}\n{diff}' },
      {
        diff = '+100%',
        cut = true,
        paths = { 'a.txt' },
        subjects = {},
        conventional = true,
      }
    )
    assert.is_truthy(text:find('Conventional Commits', 1, true))
    assert.is_truthy(text:find('(no commits yet)', 1, true))
    assert.is_truthy(text:find('+100%\n(diff cut at 512 KiB)', 1, true))
  end)

  it('fences a diff of Markdown longer than its own fences', function()
    local text = commit.build({ body = '{fence}diff\n{diff}\n{fence}' }, {
      diff = '+```lua\n+x\n+```',
      cut = false,
      paths = { 'README.md' },
      subjects = {},
      conventional = false,
    })
    assert.equals('````diff\n+```lua\n+x\n+```\n````', text)
  end)

  it('ships a prompt that fences the diff that way', function()
    local prompts = require('tools.ai.prompts')
    local shipped = prompts.read(prompts.BUILTIN .. '/git/commit.md', false)
    assert.is_truthy(shipped.body:find('{fence}diff\n{diff}\n{fence}', 1, true))
  end)
end)
