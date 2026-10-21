local h = require('helpers')

describe('util.ci_http', function()
  local http, dir, cleanup, path

  local function cli(name, lines)
    h.write(dir .. '/bin/' .. name, vim.list_extend({ '#!/bin/sh' }, lines))
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  local function await(fn)
    local done, got = false, nil
    fn(function(...)
      done, got = true, { ... }
    end)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    return got
  end

  before_each(function()
    h.unload('util.ci_http')
    http = require('util.ci_http')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin:' .. path
  end)
  after_each(function()
    vim.env.PATH = path
    cleanup()
  end)

  it('takes only a server for a server', function()
    assert.is_true(http.is_server('https://ci.example.com'))
    assert.is_true(http.is_server('http://localhost:3000/'))
    assert.is_false(http.is_server('file:///etc/passwd'))
    assert.is_false(http.is_server('https://x.example "y"'))
    assert.equals(
      'ci.example.com:8443',
      http.host('https://CI.example.com:8443/a')
    )
    assert.is_nil(http.host('ftp://x'))
  end)

  it('reads a server from the clone, else the default', function()
    vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
    local got = await(
      function(cb) http.server(dir, 'airflowUrl', 'https://d.example/', cb) end
    )
    assert.same({ 'https://d.example' }, got)
    got = await(function(cb) http.server(dir, 'airflowUrl', nil, cb) end)
    assert.same({ nil, 'No server: git config dyneo.airflowUrl <url>' }, got)
    vim
      .system(
        { 'git', 'config', 'dyneo.airflowUrl', 'https://clone.example' },
        { cwd = dir }
      )
      :wait()
    got = await(
      function(cb) http.server(dir, 'airflowUrl', 'https://d.example', cb) end
    )
    assert.same({ 'https://clone.example' }, got)
  end)

  it('gives a token only for the server it was set up for', function()
    cli('token', { 'echo secret-token' })
    local command = { dir .. '/bin/token' }
    local got = await(
      function(cb)
        http.token(command, 'https://a.example', 'https://a.example/x', cb)
      end
    )
    assert.same({ 'secret-token' }, got)
    got = await(
      function(cb)
        http.token(command, 'https://a.example', 'https://evil.example', cb)
      end
    )
    assert.same({ nil, 'The token is for a.example, not evil.example' }, got)
    got = await(
      function(cb)
        http.token(command, 'https://a.example', 'http://a.example/x', cb)
      end
    )
    assert.same({ nil, 'The token for a.example goes only over https' }, got)
    got = await(
      function(cb)
        http.token(command, 'http://a.example', 'http://a.example/x', cb)
      end
    )
    assert.same({ 'secret-token' }, got)
    got = await(function(cb) http.token(nil, nil, 'https://x', cb) end)
    assert.same({}, got)
    cli('token', { 'exit 1' })
    got = await(
      function(cb)
        http.token(command, 'https://a.example', 'https://a.example', cb)
      end
    )
    assert.same({ nil, 'token gave no token' }, got)
  end)

  it('sends a header on its input, never as an argument', function()
    cli('curl', {
      'echo "$@" > "' .. dir .. '/args"',
      'cat > "' .. dir .. '/stdin"',
      [[echo '{"ok":true}']],
    })
    local got = await(
      function(cb)
        http.json({
          url = 'https://a.example/graphql',
          method = 'POST',
          body = { query = '{ x }' },
          headers = { 'Authorization: Bearer secret-token' },
        }, cb)
      end
    )
    assert.same({ { ok = true } }, got)
    local args = vim.fn.readfile(dir .. '/args')[1]
    assert.is_nil(args:find('secret', 1, true))
    assert.is_truthy(args:find('--header @-', 1, true))
    assert.is_truthy(args:find('--netrc-optional', 1, true))
    assert.is_truthy(args:find('-- https://a.example/graphql', 1, true))
    assert.same(
      { 'Authorization: Bearer secret-token' },
      vim.fn.readfile(dir .. '/stdin')
    )
  end)

  it('keeps the end of a long answer, saying when its start is gone', function()
    cli('curl', { 'cat > /dev/null', 'printf "0123456789"' })
    local got = await(
      function(cb)
        http.tail('https://a.example/log', 4, cb, nil, { 'X-Token: t' })
      end
    )
    assert.same({ '6789', false, nil, true }, got)
  end)
end)
