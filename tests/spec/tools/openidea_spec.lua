local h = require('helpers')

describe('tools.openidea', function()
  local openidea, dir, cleanup, path, notes, restores

  before_each(function()
    h.globals()
    h.unload('tools.openidea')
    openidea = require('tools.openidea')
    dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/bin', 'p')
    path = vim.env.PATH
    -- Only the fakes of this spec, whatever the machine has
    vim.env.PATH = dir .. '/bin:/usr/bin:/bin'
    notes = {}
    restores = {
      h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg = msg, level = level }) end
      ),
      h.stub(openidea, 'dir', function() return dir .. '/jars' end),
      h.stub(openidea, 'JARS', {
        usages = { path = 'p/usages.jar', file = 'usages-1.jar' },
      }),
    }
    openidea.JARS.usages.sha256 = vim.fn.sha256('good')
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.fn.setqflist({})
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- A `curl` that writes `body` to the file after `-o`
  local function curl(body)
    h.write(dir .. '/bin/curl', {
      '#!/bin/sh',
      'while [ "$1" != "-o" ]; do shift; done',
      ('printf %%s %q > "$2"'):format(body),
    })
    vim.fn.setfperm(dir .. '/bin/curl', 'rwxr-xr-x')
  end

  it('waits out the quarantine from the pinned commit', function()
    local published = openidea.published()
    assert.is_false(openidea.released(published + 60))
    assert.is_true(openidea.released(published + DyNeo.quarantine_window))
    DyNeo.quarantine_window = 0
    assert.is_true(openidea.released(published))
  end)

  it('uses a jar only when its hash is the pinned one', function()
    assert.is_nil(openidea.ready('usages'))
    h.write(dir .. '/jars/usages-1.jar', { 'bad' })
    assert.is_nil(openidea.ready('usages'))
    local f = assert(io.open(dir .. '/jars/usages-1.jar', 'wb'))
    f:write('good')
    f:close()
    assert.equals(dir .. '/jars/usages-1.jar', openidea.ready('usages'))
  end)

  it('downloads a released jar and keeps it when the hash matches', function()
    curl('good')
    local done
    openidea.fetch(function(ok) done = ok end, math.huge)
    assert.is_true(vim.wait(3000, function() return done ~= nil end))
    assert.is_true(done)
    assert.equals(dir .. '/jars/usages-1.jar', openidea.ready('usages'))
  end)

  it('throws a download away when its hash differs, and says so', function()
    curl('tampered')
    local done
    openidea.fetch(function(ok) done = ok end, math.huge)
    assert.is_true(vim.wait(3000, function() return done ~= nil end))
    assert.is_false(done)
    assert.is_nil(openidea.ready('usages'))
    assert.same({}, vim.fn.glob(dir .. '/jars/*', true, true))
    assert.equals(vim.log.levels.ERROR, notes[#notes].level)
    assert.matches('SHA%-256', notes[#notes].msg)
  end)

  it('downloads nothing while the quarantine holds', function()
    curl('good')
    local done
    openidea.fetch(function(ok) done = ok end, openidea.published())
    assert.is_false(done)
    assert.is_nil(openidea.ready('usages'))
  end)

  --- A usage at `line` of `uri`
  local function at(uri, line, access)
    return {
      location = {
        uri = uri,
        range = {
          start = { line = line, character = 0 },
          ['end'] = { line = line, character = 1 },
        },
      },
      kind = 'field',
      access = access,
    }
  end

  it('turns usages into locations, keeping their access', function()
    local file = dir .. '/A.java'
    h.write(file, { 'x = 1;', 'y = x;', 'x += 1;', 'f(x);' })
    local uri = vim.uri_from_fname(file)
    local locations = openidea.locations({
      at(uri, 0, 'write'),
      at(uri, 1, 'read'),
      at(uri, 2, 'readWrite'),
      at(uri, 3, 'unknown'),
    })
    assert.equals(4, #locations)
    assert.equals(uri, locations[1].uri)
    assert.equals('[write]', openidea.label(file, 1, 0))
    assert.equals('[read]', openidea.label(file, 2, 0))
    assert.equals('[read/write]', openidea.label(file, 3, 0))
    assert.is_nil(openidea.label(file, 4, 0))
  end)

  describe('attach', function()
    local client, sent, answer

    before_each(function()
      sent, answer = {}, {}
      client = {
        server_capabilities = {
          executeCommandProvider = { commands = { 'openidea.java.usages' } },
        },
      }
      function client:request(method, params, handler)
        table.insert(sent, { method = method, params = params })
        local reply = answer[method] or {}
        handler(reply.err, reply.result, { method = method }, {})
        return true, #sent
      end
      openidea.attach(client)
    end)

    local params = {
      textDocument = { uri = 'file:///p/A.java' },
      position = { line = 3, character = 7 },
      context = { includeDeclaration = true },
    }

    it('answers references through the usages command', function()
      answer['workspace/executeCommand'] = {
        result = { at('file:///p/B.java', 5, 'write') },
      }
      local got
      client:request(
        'textDocument/references',
        params,
        function(err, result, ctx)
          got = { err = err, result = result, method = ctx.method }
        end
      )
      assert.equals(1, #sent)
      assert.equals('workspace/executeCommand', sent[1].method)
      assert.equals('openidea.java.usages', sent[1].params.command)
      assert.same({ 'file:///p/A.java', 3, 7, true }, sent[1].params.arguments)
      assert.is_nil(got.err)
      assert.equals('textDocument/references', got.method)
      assert.equals('file:///p/B.java', got.result[1].uri)
    end)

    it('asks for plain references when the command fails', function()
      answer['workspace/executeCommand'] = { err = { message = 'boom' } }
      answer['textDocument/references'] = {
        result = { { uri = 'file:///p/C.java' } },
      }
      local got
      client:request(
        'textDocument/references',
        params,
        function(_, result) got = result end
      )
      assert.same(
        { 'workspace/executeCommand', 'textDocument/references' },
        vim.tbl_map(function(s) return s.method end, sent)
      )
      assert.equals('file:///p/C.java', got[1].uri)
    end)

    it('leaves other requests, and a server without it, alone', function()
      client:request('textDocument/definition', params, function() end)
      assert.equals('textDocument/definition', sent[1].method)
      client.server_capabilities.executeCommandProvider.commands = {}
      client:request('textDocument/references', params, function() end)
      assert.equals('textDocument/references', sent[2].method)
    end)

    it('wraps a client once', function()
      local wrapped = client.request
      openidea.attach(client)
      assert.equals(wrapped, client.request)
    end)
  end)
end)
