local h = require('helpers')

describe('util.gitlab_auth', function()
  local auth, notes, restore_notify

  before_each(function()
    h.unload('util.gitlab_auth')
    auth = require('util.gitlab_auth')
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
  end)
  after_each(function() restore_notify() end)

  it('reads the host off every kind of remote URL', function()
    assert.equals('gitlab.com', auth.host_of('git@gitlab.com:group/repo.git'))
    assert.equals('gitlab.com', auth.host_of('https://gitlab.com/group/repo'))
    assert.equals(
      'git.example.org',
      auth.host_of('https://user@git.example.org/group/sub/repo.git')
    )
    assert.equals(
      'git.example.org',
      auth.host_of('ssh://git@git.example.org:2222/group/repo.git')
    )
    assert.is_nil(auth.host_of('/a/local/path'))
  end)

  it('reads the host a client would connect to, not one after `?@`', function()
    assert.equals(
      'evil.example',
      auth.host_of('https://evil.example?@gitlab.com')
    )
    assert.equals(
      'evil.example',
      auth.host_of('https://evil.example#@gitlab.com')
    )
    assert.equals('gitlab.com', auth.host_of('https://u:p@x@gitlab.com/g/p'))
  end)

  describe('through the CLIs', function()
    local calls, reply, restores

    before_each(function()
      calls = {}
      restores = {
        h.stub(package.loaded, 'util.system', {
          sync = function(cmd, opts)
            table.insert(calls, cmd)
            assert.is_true(opts.text)
            return reply(cmd)
          end,
        }),
        h.stub(
          vim.fn,
          'executable',
          function(name) return name == 'glab' and 1 or 0 end
        ),
      }
    end)
    after_each(function()
      for i = #restores, 1, -1 do
        restores[i]()
      end
    end)

    it('reads the URL of a remote, trimmed, or nil', function()
      reply = function() return { code = 0, stdout = ' git@x.org:g/p.git\n' } end
      assert.equals('git@x.org:g/p.git', auth.remote_url('/repo', 'origin'))
      assert.same(
        { 'git', '-C', '/repo', 'remote', 'get-url', 'origin' },
        calls[1]
      )
      reply = function() return { code = 2, stdout = 'fatal' } end
      assert.is_nil(auth.remote_url('/repo', 'origin'))
      reply = function() return { code = 0 } end
      assert.is_nil(auth.remote_url('/repo', 'origin'))
    end)

    it('asks glab for the token of a host', function()
      reply = function() return { code = 0, stdout = 'glpat-x\n' } end
      assert.equals('glpat-x', auth.glab_token('git.example.org'))
      assert.same(
        { 'glab', 'config', 'get', 'token', '--host', 'git.example.org' },
        calls[1]
      )
      reply = function() return { code = 1, stdout = '' } end
      assert.is_nil(auth.glab_token('git.example.org'))
    end)

    it('keeps the tokens of the environment from another host', function()
      local env
      restores[1]()
      restores[1] = h.stub(package.loaded, 'util.system', {
        sync = function(_, opts)
          env = opts.env
          return { code = 1, stdout = '' }
        end,
      })
      local restore_host = h.stub(vim.env, 'GITLAB_HOST', 'gitlab.corp.example')
      local restore_token = h.stub(vim.env, 'GITLAB_ACCESS_TOKEN', 'glpat-corp')
      auth.glab_token('evil.example')
      restore_token()
      restore_host()
      assert.is_table(env)
      assert.is_nil(env.GITLAB_ACCESS_TOKEN)
    end)

    it('asks nothing of a glab that is not installed', function()
      restores[2]()
      restores[2] = h.stub(vim.fn, 'executable', function() return 0 end)
      assert.is_nil(auth.glab_token('git.example.org'))
      assert.same({}, calls)
    end)
  end)

  describe('auth', function()
    local restores, saved_env

    before_each(function()
      saved_env = { vim.env.GITLAB_TOKEN, vim.env.GITLAB_URL }
      vim.env.GITLAB_TOKEN = nil
      vim.env.GITLAB_URL = nil
      restores = {
        h.stub(
          auth,
          'remote_url',
          function() return 'git@git.example.org:group/repo.git' end
        ),
      }
    end)
    after_each(function()
      for _, restore in ipairs(restores) do
        restore()
      end
      vim.env.GITLAB_TOKEN, vim.env.GITLAB_URL = saved_env[1], saved_env[2]
    end)

    it('keeps the environment token off a URL the repository names', function()
      vim.env.GITLAB_TOKEN = 'from-env'
      local token, url = auth.auth(
        function() return 'from-env', 'https://attacker.example' end,
        'origin'
      )
      assert.equals('from-env', token)
      assert.is_nil(url)
      assert.is_truthy(notes[1]:find('GITLAB_TOKEN', 1, true))

      vim.env.GITLAB_URL = 'https://git.example.org'
      token, url = auth.auth(
        function() return 'from-env', 'https://attacker.example' end,
        'origin'
      )
      assert.equals('https://git.example.org', url)
    end)

    it('lets a repository file name the URL of its own token', function()
      vim.env.GITLAB_TOKEN = 'from-env'
      local token, url = auth.auth(
        function() return 'from-file', 'https://file.example' end,
        'origin'
      )
      assert.equals('from-file', token)
      assert.equals('https://file.example', url)
    end)

    it('takes what the plugin found itself', function()
      table.insert(
        restores,
        h.stub(auth, 'glab_token', function() error('asked glab') end)
      )
      local token, url = auth.auth(
        function() return 'from-file', 'https://file.example' end,
        'origin'
      )
      assert.equals('from-file', token)
      assert.equals('https://file.example', url)
    end)

    it('fills the token from glab and the URL from the remote', function()
      local asked
      table.insert(
        restores,
        h.stub(auth, 'glab_token', function(host)
          asked = host
          return 'from-glab'
        end)
      )
      local token, url, err = auth.auth(
        function() return nil, nil end,
        'origin'
      )
      assert.equals('git.example.org', asked)
      assert.equals('from-glab', token)
      assert.equals('https://git.example.org', url)
      assert.is_nil(err)
    end)

    it('keeps a token from the environment on its own host', function()
      table.insert(
        restores,
        h.stub(auth, 'glab_token', function() error('asked glab') end)
      )
      local token, url = auth.auth(
        function() return 'from-env', nil end,
        'origin'
      )
      assert.equals('from-env', token)
      -- Not `origin`'s host: the token may be another server's
      assert.is_nil(url)
    end)

    it('asks glab for the token of the URL a repository file names', function()
      local asked
      table.insert(
        restores,
        h.stub(auth, 'glab_token', function(host)
          asked = host
          return nil
        end)
      )
      local token, _, err = auth.auth(
        function() return nil, 'https://attacker.example' end,
        'origin'
      )
      assert.equals('attacker.example', asked)
      assert.is_nil(token)
      assert.is_truthy(err)
    end)

    it('says why when there is no token anywhere', function()
      table.insert(
        restores,
        h.stub(auth, 'glab_token', function() return nil end)
      )
      local token, _, err = auth.auth(function() return '', nil end, 'origin')
      assert.is_nil(token)
      assert.is_truthy(err:find('glab auth login', 1, true))
      assert.equals(err, notes[1])
    end)
  end)
end)
