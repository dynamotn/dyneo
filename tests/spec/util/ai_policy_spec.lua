local h = require('helpers')

describe('util.ai_policy', function()
  local policy, dir, cleanup

  before_each(function()
    dir, cleanup = h.tmpdir()
    _G.DyNeo.ai = { local_only = {}, local_providers = { 'ollama' } }
    h.unload('util.ai_policy')
    policy = require('util.ai_policy')
  end)
  after_each(function()
    _G.DyNeo.ai = nil
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  it('resolves a path once while its answer is kept', function()
    h.write(dir .. '/proj/main.lua', { 'x' })
    local calls = 0
    local realpath = vim.uv.fs_realpath
    local restore = h.stub(vim.uv, 'fs_realpath', function(...)
      calls = calls + 1
      return realpath(...)
    end)
    policy.local_only(dir .. '/proj/main.lua')
    local first = calls
    policy.local_only(dir .. '/proj/main.lua')
    restore()
    assert.is_true(first > 0)
    assert.equals(first, calls)
  end)

  it('judges a buffer with no file by the working directory', function()
    h.write(dir .. '/proj/.nvim/ai.json', { '{ "local_only": true }' })
    local cwd = vim.fn.getcwd()
    vim.cmd.cd(dir .. '/proj')
    vim.api.nvim_set_current_buf(h.buffer())
    assert.truthy(policy.local_only())
    local uri = h.buffer({ name = 'octo://org/repo/pull/1' })
    assert.truthy(policy.local_only(uri))
    vim.cmd.cd(cwd)
  end)

  it('leaves a project that says nothing alone', function()
    h.write(dir .. '/proj/main.lua', { 'x' })
    assert.is_nil(policy.local_only(dir .. '/proj/main.lua'))
  end)

  it('keeps AI local below a .nvim/ai.json that says so', function()
    h.write(dir .. '/proj/.nvim/ai.json', { '{ "local_only": true }' })
    h.write(dir .. '/proj/src/main.lua', { 'x' })
    local reason = policy.local_only(dir .. '/proj/src/main.lua')
    assert.is_truthy(reason and reason:find('ai.json', 1, true))
    assert.is_not_nil(policy.local_only(dir .. '/proj'))
  end)

  it('takes a file that does not read as keeping AI local', function()
    h.write(dir .. '/proj/.nvim/ai.json', { 'not json' })
    assert.is_not_nil(policy.local_only(dir .. '/proj/x.lua'))
  end)

  it('lets a project say it need not keep AI local', function()
    h.write(dir .. '/proj/.nvim/ai.json', { '{ "local_only": false }' })
    assert.is_nil(policy.local_only(dir .. '/proj/x.lua'))
  end)

  it('keeps the folders of DyNeo.ai.local_only local, by whole name', function()
    DyNeo.ai.local_only = { dir .. '/proj' }
    vim.fn.mkdir(dir .. '/proj', 'p')
    vim.fn.mkdir(dir .. '/proj-other', 'p')
    assert.is_not_nil(policy.local_only(dir .. '/proj/a.lua'))
    assert.is_nil(policy.local_only(dir .. '/proj-other/a.lua'))
  end)

  it('asks about the file of a buffer', function()
    h.write(dir .. '/proj/.nvim/ai.json', { '{}' })
    local bufnr = h.buffer({ name = dir .. '/proj/a.lua' })
    assert.is_not_nil(policy.local_only(bufnr))
  end)

  it('remembers an answer for a while', function()
    vim.fn.mkdir(dir .. '/proj', 'p')
    assert.is_nil(policy.local_only(dir .. '/proj/a.lua'))
    h.write(dir .. '/proj/.nvim/ai.json', { '{}' })
    assert.is_nil(policy.local_only(dir .. '/proj/a.lua'))
    policy.reset()
    assert.is_not_nil(policy.local_only(dir .. '/proj/a.lua'))
  end)

  it('names the local providers', function()
    assert.is_true(policy.is_local_provider('ollama'))
    assert.is_false(policy.is_local_provider('claude-code'))
  end)

  describe('command', function()
    it('is the commit command where AI may leave', function()
      DyNeo.ai.commit_command = { 'claude', '-p' }
      vim.fn.mkdir(dir .. '/proj', 'p')
      assert.same({ 'claude', '-p' }, policy.command(dir .. '/proj'))
    end)

    it('is the local command where AI stays local, or none', function()
      h.write(dir .. '/proj/.nvim/ai.json', { '{}' })
      local cmd, why = policy.command(dir .. '/proj')
      assert.is_nil(cmd)
      assert.is_truthy(why:find('local_command', 1, true))
      DyNeo.ai.local_command = { 'ollama', 'run', 'qwen' }
      assert.same({ 'ollama', 'run', 'qwen' }, policy.command(dir .. '/proj'))
    end)
  end)
end)
