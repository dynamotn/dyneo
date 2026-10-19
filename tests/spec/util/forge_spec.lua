local h = require('helpers')

describe('util.forge', function()
  local forge, dir, cleanup

  before_each(function()
    h.unload('util.forge')
    forge = require('util.forge')
    dir, cleanup = h.tmpdir()
  end)
  after_each(function() cleanup() end)

  it('reads the host and path of every kind of clone URL', function()
    local cases = {
      ['https://github.com/o/r.git'] = { 'github.com', 'o/r' },
      ['https://user@GitLab.com/g/sub/p'] = { 'gitlab.com', 'g/sub/p' },
      ['ssh://git@gitlab.example.org:2222/g/p.git'] = {
        'gitlab.example.org',
        'g/p',
      },
      ['git@github.com:o/r.git'] = { 'github.com', 'o/r' },
      ['git@github.com:o/r/'] = { 'github.com', 'o/r' },
    }
    for url, expected in pairs(cases) do
      assert.same(expected, { forge.parse_url(url) }, url)
    end
    assert.is_nil(forge.parse_url('/local/path'))
  end)

  it('tells the forge by its host', function()
    assert.equals('github', forge.kind_of('github.com'))
    assert.equals('github', forge.kind_of('github.example.com'))
    assert.equals('gitlab', forge.kind_of('gitlab.com'))
    assert.equals('gitlab', forge.kind_of('gitlab.internal'))
    assert.is_nil(forge.kind_of('codeberg.org'))
    assert.equals('azure', forge.kind_of('dev.azure.com'))
    assert.equals('azure', forge.kind_of('ssh.dev.azure.com'))
    assert.equals('azure', forge.kind_of('contoso.visualstudio.com'))
    -- An organization called after another forge is still on Azure
    assert.equals('azure', forge.kind_of('mygitlab.visualstudio.com'))
    assert.is_nil(forge.kind_of('dev.azure.com.attacker.example'))
  end)

  it(
    'reads the organization, project and repository of Azure DevOps',
    function()
      local expected = {
        kind = 'azure',
        host = 'dev.azure.com',
        slug = 'contoso/My Project/web',
        org = 'contoso',
        project = 'My Project',
        repo = 'web',
      }
      for _, url in ipairs({
        'https://contoso@dev.azure.com/contoso/My%20Project/_git/web',
        'git@ssh.dev.azure.com:v3/contoso/My%20Project/web',
        'https://contoso.visualstudio.com/My%20Project/_git/web',
        'https://contoso.visualstudio.com/DefaultCollection/My%20Project/_git/web',
        'contoso@vs-ssh.visualstudio.com:v3/contoso/My%20Project/web',
      }) do
        local remote = forge.pick_remote({ origin = url })
        assert.is_table(remote, url)
        remote.name = nil
        assert.same(expected, remote, url)
      end
      -- Not a repository, or an organization that would bend the API's URL
      assert.is_nil(
        forge.pick_remote({ origin = 'https://dev.azure.com/contoso/p' })
      )
      assert.is_nil(forge.azure_parts('dev.azure.com', 'a.b#/p/_git/r'))
      assert.is_nil(forge.azure_parts('dev.azure.com', 'o/p%0A/_git/r'))
    end
  )

  it('asks Azure DevOps through az devops invoke, at its own host', function()
    local remote = forge.pick_remote({
      origin = 'https://contoso.visualstudio.com/My%20Project/_git/web',
    })
    local command, name = forge.command(remote, {
      area = 'build',
      resource = 'builds',
      route = { project = 'My Project' },
      query = { branchName = 'refs/heads/main', ['$top'] = 1 },
    })
    assert.equals('az devops invoke', name)
    assert.same({
      'az',
      'devops',
      'invoke',
      '--organization',
      'https://dev.azure.com/contoso',
      '--detect',
      'false',
      '--area',
      'build',
      '--resource',
      'builds',
      '--api-version',
      forge.AZURE_API_VERSION,
      '--http-method',
      'GET',
      '--output',
      'json',
      '--only-show-errors',
      '--route-parameters',
      'project=My Project',
      '--query-parameters',
      '$top=1',
      'branchName=refs/heads/main',
    }, command)
  end)

  it('takes the first remote on a known forge, in order', function()
    local function git(...)
      vim.system(vim.list_extend({ 'git' }, { ... }), { cwd = dir }):wait()
    end
    git('init', '-q', '-b', 'trunk')
    git('remote', 'add', 'origin', 'git@gitlab.com:g/p.git')
    git('remote', 'add', 'upstream', 'https://codeberg.org/x/y')
    git('remote', 'add', 'gh', 'https://github.com/o/r')

    --- What an asynchronous lookup hands back, waited for
    local function await(fn, path)
      local done, value = false, nil
      fn(path, function(result)
        done, value = true, result
      end)
      -- Nothing is answered before the main loop turns
      assert.is_false(done)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      return value
    end
    assert.same(
      { name = 'gh', host = 'github.com', slug = 'o/r', kind = 'github' },
      await(forge.remote, dir)
    )
    assert.equals('trunk', await(forge.branch, dir))
    vim.fn.mkdir(dir .. '/nowhere', 'p')
    assert.is_nil(await(forge.remote, vim.fn.tempname()))
  end)

  it('picks the remote in order, the slug kept', function()
    assert.same(
      { name = 'origin', host = 'gitlab.com', slug = 'g/p', kind = 'gitlab' },
      forge.pick_remote({
        origin = 'git@gitlab.com:g/p.git',
        upstream = 'https://codeberg.org/x/y',
      })
    )
    assert.is_nil(forge.pick_remote({}))
  end)

  it(
    'percent-encodes a path segment',
    function() assert.equals('g%2Fsub%2Fp', forge.encode('g/sub/p')) end
  )

  describe('api', function()
    local path

    before_each(function()
      vim.fn.mkdir(dir .. '/bin', 'p')
      path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
    end)
    after_each(function() vim.env.PATH = path end)

    local function cli(name, lines)
      h.write(dir .. '/bin/' .. name, vim.list_extend({ '#!/bin/sh' }, lines))
      vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
    end

    local function call(remote, endpoint)
      local done, data, err = false, nil, nil
      forge.api(remote, endpoint, function(d, e)
        done, data, err = true, d, e
      end)
      assert.is_true(vim.wait(5000, function() return done end, 10))
      return data, err
    end

    it('asks gh for GitHub and glab for GitLab, on the right host', function()
      cli(
        'gh',
        { 'echo "$@" > "' .. dir .. '/gh.args"', [[echo '{"a":null,"b":[1]}']] }
      )
      cli('glab', { 'echo "$@" > "' .. dir .. '/glab.args"', 'echo "[]"' })
      local data = call(
        { kind = 'github', host = 'github.com', slug = 'o/r', name = 'gh' },
        'repos/o/r'
      )
      assert.same({ b = { 1 } }, data)
      assert.same(
        { 'api --hostname github.com repos/o/r' },
        vim.fn.readfile(dir .. '/gh.args')
      )
      assert.same(
        {},
        call(
          { kind = 'gitlab', host = 'gitlab.x', slug = 'g/p', name = 'origin' },
          'projects'
        )
      )
      assert.same(
        { 'api --hostname gitlab.x projects' },
        vim.fn.readfile(dir .. '/glab.args')
      )
    end)

    describe('environment tokens', function()
      local saved

      before_each(function()
        saved = {}
        for _, var in ipairs({
          'GITLAB_TOKEN',
          'GITLAB_HOST',
          'GL_HOST',
          'GH_ENTERPRISE_TOKEN',
          'GH_HOST',
        }) do
          saved[var] = vim.env[var]
          vim.env[var] = nil
        end
        vim.env.GITLAB_TOKEN = 'gl-env-token'
        vim.env.GH_ENTERPRISE_TOKEN = 'gh-env-token'
        cli('glab', {
          'echo "token=$GITLAB_TOKEN" > "' .. dir .. '/glab.seen"',
          'echo "[]"',
        })
        cli('gh', {
          'echo "token=$GH_ENTERPRISE_TOKEN" > "' .. dir .. '/gh.seen"',
          'echo "[]"',
        })
      end)
      after_each(function()
        for var, value in pairs(saved) do
          vim.env[var] = value
        end
      end)

      local function seen(kind, host)
        local cli_name = kind == 'github' and 'gh' or 'glab'
        call({ kind = kind, host = host, slug = 'g/p', name = 'origin' }, 'x')
        return vim.fn.readfile(dir .. '/' .. cli_name .. '.seen')[1]
      end

      it('keeps them from a host a repository names', function()
        assert.equals('token=', seen('gitlab', 'gitlab.attacker.example'))
        assert.equals('token=', seen('github', 'github.attacker.example'))
      end)

      it(
        'passes them to the default host',
        function()
          assert.equals('token=gl-env-token', seen('gitlab', 'gitlab.com'))
        end
      )

      it('passes them to the host the user named', function()
        vim.env.GITLAB_HOST = 'https://gitlab.corp.example'
        vim.env.GH_HOST = 'github.corp.example'
        assert.equals(
          'token=gl-env-token',
          seen('gitlab', 'gitlab.corp.example')
        )
        assert.equals(
          'token=gh-env-token',
          seen('github', 'github.corp.example')
        )
        assert.equals('token=', seen('gitlab', 'gitlab.attacker.example'))
      end)
    end)

    it('says when the CLI is not installed', function()
      vim.env.PATH = dir .. '/bin'
      local data, err = call(
        { kind = 'github', host = 'github.com', slug = 'o/r', name = 'gh' },
        'x'
      )
      assert.is_nil(data)
      assert.equals('gh is not installed', err)
    end)

    it('takes half a JSON document for no answer', function()
      local max = require('util.system').MAX_BYTES
      cli('gh', {
        ('head -c %d /dev/zero | tr "\\0" a'):format(max + 1024),
        'exit 0',
      })
      local data, err = call(
        { kind = 'github', host = 'github.com', slug = 'o/r', name = 'gh' },
        'x'
      )
      assert.is_nil(data)
      assert.equals('gh api answered with more than can be read', err)
    end)

    describe('api_text', function()
      local remote =
        { kind = 'gitlab', host = 'gitlab.com', slug = 'g/p', name = 'origin' }

      local function call_text(max_bytes)
        local done, text, cut, err = false, nil, nil, nil
        forge.api_text(remote, 'jobs/1/trace', max_bytes, function(t, c, e)
          done, text, cut, err = true, t, c, e
        end)
        assert.is_true(vim.wait(5000, function() return done end, 10))
        return text, cut, err
      end

      it('hands over the text, cut at the size given', function()
        cli('glab', {
          'echo "$@" > "' .. dir .. '/glab.args"',
          'printf "line one\\nline two\\n"',
        })
        local text, cut, err = call_text(1024)
        assert.equals('line one\nline two\n', text)
        assert.is_false(cut)
        assert.is_nil(err)
        assert.same(
          { 'api --hostname gitlab.com jobs/1/trace' },
          vim.fn.readfile(dir .. '/glab.args')
        )
        text, cut = call_text(4)
        assert.equals('line', text)
        assert.is_true(cut)
      end)

      it('says why there is no text', function()
        cli('glab', { 'echo "HTTP 403" >&2', 'exit 1' })
        local text, cut, err = call_text(1024)
        assert.is_nil(text)
        assert.is_false(cut)
        assert.equals('HTTP 403', err)
        vim.env.PATH = dir .. '/bin'
        vim.fn.delete(dir .. '/bin/glab')
        text, cut, err = call_text(1024)
        assert.is_nil(text)
        assert.equals('glab is not installed', err)
      end)
    end)

    describe('on Azure DevOps', function()
      local remote = {
        kind = 'azure',
        host = 'dev.azure.com',
        slug = 'o/p/r',
        name = 'origin',
        org = 'o',
        project = 'p',
        repo = 'r',
      }
      local logs = {
        area = 'build',
        resource = 'logs',
        route = { project = 'p', buildId = 1, logId = 2 },
      }

      it('never lets az offer to install its extension', function()
        cli('az', {
          'echo "$AZURE_EXTENSION_USE_DYNAMIC_INSTALL" > "'
            .. dir
            .. '/az.seen"',
          [[echo '{"count":1,"value":[{"id":3}]}']],
        })
        local data = call(remote, logs)
        assert.same({ count = 1, value = { { id = 3 } } }, data)
        assert.same({ 'no' }, vim.fn.readfile(dir .. '/az.seen'))
      end)

      it('reads a log from its lines', function()
        cli('az', { [[echo '{"count":2,"value":["one","two"]}']] })
        local done, text, cut, err = false, nil, nil, nil
        forge.api_text(remote, logs, 1024, function(t, c, e)
          done, text, cut, err = true, t, c, e
        end)
        assert.is_true(vim.wait(5000, function() return done end, 10))
        assert.equals('one\ntwo', text)
        assert.is_false(cut)
        assert.is_nil(err)

        -- A log cut short is no JSON to read: said, not half read
        done = false
        forge.api_text(remote, logs, 8, function(t, c, e)
          done, text, cut, err = true, t, c, e
        end)
        assert.is_true(vim.wait(5000, function() return done end, 10))
        assert.is_nil(text)
        assert.equals(
          'az devops invoke answered with more than can be read',
          err
        )
      end)

      it('says when az is not installed', function()
        vim.env.PATH = dir .. '/bin'
        local data, err = call(remote, logs)
        assert.is_nil(data)
        assert.equals('az is not installed', err)
      end)
    end)

    it('says why there is no answer', function()
      cli('gh', { 'echo "HTTP 404" >&2', 'exit 1' })
      local remote =
        { kind = 'github', host = 'github.com', slug = 'o/r', name = 'gh' }
      local data, err = call(remote, 'x')
      assert.is_nil(data)
      assert.equals('HTTP 404', err)
      cli('gh', { 'echo "<html>"' })
      _, err = call(remote, 'x')
      assert.equals('gh api answered with something not JSON', err)
    end)
  end)
end)
