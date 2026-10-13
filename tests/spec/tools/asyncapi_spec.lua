local h = require('helpers')

describe('tools.asyncapi', function()
  local asyncapi

  before_each(function()
    h.unload('tools.asyncapi')
    asyncapi = require('tools.asyncapi')
  end)

  local doc = {
    'asyncapi: 3.0.0',
    'info:',
    '  title: Accounts',
    'channels:',
    '  userSignedUp:',
    '    address: user/signedup',
    '    messages:',
    '      userSignedUp:',
    '        payload:',
    '          type: object',
    '  userDeleted:',
    '    address: user/deleted',
  }

  it('knows an AsyncAPI document by its first lines', function()
    assert.is_true(asyncapi.is_document(doc))
    assert.is_true(asyncapi.is_document({ '{', '  "asyncapi": "3.0.0",' }))
    assert.is_false(asyncapi.is_document({ 'openapi: 3.1.0' }))
  end)

  it('finds the line a JSON pointer is about', function()
    assert.equals(
      9,
      asyncapi.line_of(
        doc,
        '/channels/userSignedUp/messages/userSignedUp/payload'
      )
    )
    assert.equals(12, asyncapi.line_of(doc, '/channels/userDeleted/address'))
    -- Not in the buffer any more: the deepest key that still is
    assert.equals(11, asyncapi.line_of(doc, '/channels/userDeleted/messages'))
    assert.equals(1, asyncapi.line_of(doc, '/components'))
  end)

  it('makes a diagnostic of each change, bare list or not', function()
    local changes = {
      { action = 'remove', path = '/channels/userDeleted', type = 'breaking' },
    }
    local diagnostics = asyncapi.diagnostics(changes, doc)
    assert.same({
      lnum = 10,
      col = 0,
      severity = vim.diagnostic.severity.ERROR,
      message = 'remove /channels/userDeleted',
      source = 'asyncapi',
    }, diagnostics[1])
    assert.equals(1, #asyncapi.diagnostics({
      changes = {
        { action = 'edit', path = '/info', type = 'non-breaking' },
      },
    }, doc))
  end)

  describe('diff', function()
    local dir, cleanup, path, notes, restore

    before_each(function()
      dir, cleanup = h.tmpdir()
      path = vim.env.PATH
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg, level }) end
      )
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
      h.write(dir .. '/asyncapi.yaml', doc)
      vim.system({ 'git', 'add', '.' }, { cwd = dir }):wait()
      vim
        .system({
          'git',
          '-c',
          'user.name=t',
          '-c',
          'user.email=t@t',
          'commit',
          '-qm',
          'x',
          '--no-verify',
        }, { cwd = dir })
        :wait()
      vim.cmd.edit(dir .. '/asyncapi.yaml')
      asyncapi.STATE = dir .. '/state/copies.json'
    end)
    after_each(function()
      restore()
      vim.env.PATH = path
      vim.cmd('silent! %bwipeout!')
      cleanup()
    end)

    ---@param body string[]
    local function fake(body)
      local bin = dir .. '/bin'
      h.write(bin .. '/asyncapi', vim.list_extend({ '#!/bin/sh' }, body))
      vim.fn.setfperm(bin .. '/asyncapi', 'rwxr-xr-x')
      vim.env.PATH = bin .. ':' .. path
    end

    it('shows what breaks, and leaves no copy behind', function()
      fake({
        'test -f "$2" && test -f "$3" || exit 9',
        -- Its analytics stay off
        'test "$CI" = true || exit 8',
        [[echo '[{"action":"remove","path":"/channels/userDeleted","type":"breaking"}]']],
      })
      asyncapi.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same(
        { '1 breaking changes since HEAD', vim.log.levels.WARN },
        notes[1]
      )
      assert.equals(1, #vim.diagnostic.get(0))
      assert.is_nil(vim.uv.fs_stat(dir .. '/.asyncapi-base-asyncapi.yaml'))
      assert.is_nil(vim.uv.fs_stat(dir .. '/.asyncapi-revision-asyncapi.yaml'))
    end)

    describe('with a copy in the way', function()
      local base = '/.asyncapi-base-asyncapi.yaml'

      before_each(function() fake({ [[echo '[]']] }) end)

      ---@param pid integer
      local function recorded(pid)
        h.write(dir .. base, { 'left over' })
        h.write(asyncapi.STATE, { vim.json.encode({ [dir .. base] = pid }) })
      end

      it('removes one a session that has ended left', function()
        local ended = vim.system({ 'true' })
        ended:wait()
        recorded(ended.pid)
        asyncapi.diff(0)
        vim.wait(5000, function() return #notes > 0 end)
        assert.same({ 'Nothing breaks since HEAD' }, { notes[1][1] })
        assert.is_nil(vim.uv.fs_stat(dir .. base))
        assert.same(
          {},
          vim.json.decode(table.concat(vim.fn.readfile(asyncapi.STATE)))
        )
      end)

      it('leaves one it did not write, or a live session writes', function()
        h.write(dir .. base, { 'mine' })
        asyncapi.diff(0)
        vim.wait(5000, function() return #notes > 0 end)
        recorded(1)
        asyncapi.diff(0)
        vim.wait(5000, function() return #notes > 1 end)
        for _, note in ipairs(notes) do
          assert.same({
            '.asyncapi-base-asyncapi.yaml is in the way: not written over',
            vim.log.levels.ERROR,
          }, note)
        end
        assert.same({ 'left over' }, vim.fn.readfile(dir .. base))
      end)
    end)

    it('says a failed run failed', function()
      fake({ 'echo "not an AsyncAPI document" >&2', 'exit 1' })
      asyncapi.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same({
        'asyncapi diff failed: not an AsyncAPI document',
        vim.log.levels.ERROR,
      }, notes[1])
    end)
  end)
end)
