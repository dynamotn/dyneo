local h = require('helpers')

describe('util.ai_audit', function()
  local audit, dir, cleanup, restore_file

  before_each(function()
    dir, cleanup = h.tmpdir()
    h.unload('util.ai_audit')
    audit = require('util.ai_audit')
    restore_file = h.stub(
      audit,
      'file',
      function() return dir .. '/state/ai_audit.jsonl' end
    )
  end)
  after_each(function()
    restore_file()
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('logs a handover once a minute', function()
    assert.is_true(audit.record('Avante', 'sent', '/a.lua', 'ask', 1000))
    assert.is_false(audit.record('Avante', 'sent', '/a.lua', 'ask', 1030))
    assert.is_true(audit.record('Avante', 'sent', '/a.lua', 'edit', 1030))
    assert.is_true(audit.record('Avante', 'refused', '/a.lua', 'ask', 1030))
    assert.is_true(audit.record('Avante', 'sent', '/a.lua', 'ask', 1060))
    assert.equals(4, #audit.entries)
  end)

  it('keeps every session in the file, and nothing of the text', function()
    audit.record('Copilot', 'sent', '/repo/main.lua', 'attached', 1000)
    audit.record('Claude Code', 'refused', '/repo/.env', nil, 1001)
    audit.reset()
    assert.same({}, audit.entries)

    local history = audit.history()
    assert.equals(2, #history)
    assert.same({
      time = 1000,
      integration = 'Copilot',
      action = 'sent',
      what = '/repo/main.lua',
      detail = 'attached',
    }, history[1])
    assert.equals('/repo/.env', history[2].what)
  end)

  it('names a buffer that is gone by its number', function()
    local bufnr = h.buffer()
    vim.api.nvim_buf_delete(bufnr, { force = true })
    assert.equals(('[buffer %d]'):format(bufnr), audit.describe_buffer(bufnr))
  end)

  it('keeps only the newer half of a log past a megabyte', function()
    local line = vim.json.encode({
      time = 1,
      integration = 'Copilot',
      action = 'sent',
      what = ('/repo/%s.lua'):format(('x'):rep(100)),
    })
    local lines = {}
    for i = 1, math.ceil(1024 * 1024 / #line) + 1 do
      lines[i] = line
    end
    h.write(audit.file(), lines)
    audit.record('Copilot', 'sent', '/repo/new.lua', nil, 2)
    local kept = vim.fn.readfile(audit.file())
    assert.is_true(#kept < #lines)
    assert.is_true(#kept >= math.floor(#lines / 2))
    assert.truthy(kept[#kept]:find('/repo/new.lua', 1, true))
  end)

  it('skips a line of the file that does not decode', function()
    h.write(audit.file(), {
      '{"time":1,"integration":"Avante","action":"sent","what":"/x"}',
      '{"time":2,"integr',
    })
    assert.equals(1, #audit.history())
  end)

  it('formats an entry on one line', function()
    local line = audit.format({
      time = os.time({ year = 2026, month = 10, day = 9, hour = 14 }),
      integration = 'sidekick',
      action = 'sent',
      what = '/nowhere/file.lua',
      detail = 'prompt review',
    })
    assert.equals(
      '2026-10-09 14:00:00  sent     sidekick     /nowhere/file.lua'
        .. '  (prompt review)',
      line
    )
  end)

  it('names a buffer by its path, or by its number', function()
    local named = h.buffer({ name = dir .. '/a.lua' })
    local unnamed = h.buffer()
    assert.equals(dir .. '/a.lua', audit.describe_buffer(named))
    assert.equals(
      ('[No Name %d]'):format(unnamed),
      audit.describe_buffer(unnamed)
    )
  end)

  it('logs a decrypted buffer, written by a handler of its own', function()
    local bufnr = h.buffer({ name = dir .. '/secrets.yaml' })
    vim.bo[bufnr].buftype = 'acwrite'
    assert.is_true(audit.record_buffer('Avante', 'refused', bufnr))
  end)

  it('keeps its file to this user', function()
    audit.record('Avante', 'sent', dir .. '/a')
    assert.equals('rw-------', vim.fn.getfperm(audit.file()))
  end)

  it('leaves out a buffer that is no file', function()
    local scratch = h.buffer({ name = dir .. '/chat' })
    vim.bo[scratch].buftype = 'nofile'
    assert.is_false(audit.record_buffer('Avante', 'sent', scratch))
    assert.is_true(
      audit.record_buffer('Avante', 'sent', h.buffer({ name = dir .. '/b' }))
    )
  end)

  it('shows the session newest first, and every session with a bang', function()
    audit.command()
    audit.record('Avante', 'sent', '/one', nil, 1000)
    audit.record('Avante', 'sent', '/two', nil, 1001)

    vim.cmd('DyAiGuardLog')
    local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
    assert.equals('Handed to the AI integrations, this session', lines[1])
    assert.is_truthy(lines[3]:find('/two', 1, true))
    assert.is_truthy(lines[4]:find('/one', 1, true))
    vim.cmd('close')

    audit.reset()
    vim.cmd('DyAiGuardLog')
    assert.equals(
      'Nothing was handed over.',
      vim.api.nvim_buf_get_lines(0, 2, 3, false)[1]
    )
    vim.cmd('close')

    vim.cmd('DyAiGuardLog!')
    assert.equals(4, vim.api.nvim_buf_line_count(0))
    vim.cmd('close')
  end)
end)
