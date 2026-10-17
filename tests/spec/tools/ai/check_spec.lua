local h = require('helpers')

describe('tools.ai.check', function()
  local check, dir, cleanup, path

  --- A fake `betterleaks` running `body`
  local function betterleaks(body)
    h.write(dir .. '/bin/betterleaks', vim.list_extend({ '#!/bin/sh' }, body))
    vim.fn.setfperm(dir .. '/bin/betterleaks', 'rwxr-xr-x')
  end

  --- What `check.text` answers, once it has
  local function verdict(paths, text)
    local done, reason = false, nil
    check.text(dir, paths, text, function(why)
      done, reason = true, why
    end)
    assert.is_true(vim.wait(5000, function() return done end, 20))
    return reason
  end

  before_each(function()
    dir, cleanup = h.tmpdir()
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
    betterleaks({ 'cat > "' .. dir .. '/scanned"', 'echo "[]"' })
    h.unload('tools.ai.check')
    check = require('tools.ai.check')
  end)
  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  it('lets plain text through once betterleaks has read it', function()
    assert.is_nil(verdict({ 'a.txt' }, '+two'))
    assert.same({ '+two' }, vim.fn.readfile(dir .. '/scanned'))
  end)

  it('refuses a path kept from AI without running betterleaks', function()
    local reason = verdict({ 'keys/id_ed25519' }, '+x')
    assert.is_truthy(reason:find('id_ed25519', 1, true))
    assert.is_nil(vim.uv.fs_stat(dir .. '/scanned'))
  end)

  it('finds a credential on any line, a removed one too', function()
    local token = '-token = "ghp_' .. ('a'):rep(36) .. '"'
    assert.is_not_nil(check.refusal(dir, {}, 'context\n' .. token))
  end)

  it('scans with its own rules, whatever the repository allows', function()
    h.write(dir .. '/.betterleaks.toml', { '[allowlist]', 'regexes = [".*"]' })
    betterleaks({
      'cat > /dev/null',
      'for a in "$@"; do echo "$a"; done > "' .. dir .. '/args"',
      'pwd > "' .. dir .. '/cwd"',
      'echo "[]"',
    })
    assert.is_nil(verdict({}, 'x'))
    local args = vim.fn.readfile(dir .. '/args')
    assert.is_true(vim.list_contains(args, '--ignore-gitleaks-allow'))
    local config
    for _, arg in ipairs(args) do
      config = config or arg:match('^%-%-config=(.+)$')
    end
    assert.same({ '[extend]', 'useDefault = true' }, vim.fn.readfile(config))
    assert.are_not.equal(dir, vim.fn.readfile(dir .. '/cwd')[1])
  end)

  it('refuses what betterleaks finds, naming its rules', function()
    betterleaks({
      'cat > /dev/null',
      [[echo '[{"RuleID":"b-key"},{"RuleID":"a-key"},{"RuleID":"a-key"}]']],
    })
    assert.equals('betterleaks found a-key, b-key in it', verdict({}, 'x'))
  end)

  it('refuses when betterleaks cannot check', function()
    betterleaks({ 'cat > /dev/null', 'exit 2' })
    assert.is_truthy(verdict({}, 'x'):find('could not check', 1, true))
    betterleaks({ 'cat > /dev/null', 'echo "not json"' })
    assert.is_truthy(verdict({}, 'x'):find('does not read', 1, true))
  end)
end)
