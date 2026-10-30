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

      it('writes nothing through a link pointing nowhere', function()
        local target = dir .. '/planted'
        assert(vim.uv.fs_symlink(target, dir .. base))
        asyncapi.diff(0)
        vim.wait(5000, function() return #notes > 0 end)
        assert.same({
          '.asyncapi-base-asyncapi.yaml is in the way: not written over',
          vim.log.levels.ERROR,
        }, notes[1])
        assert.is_nil(vim.uv.fs_stat(target))
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

    it('says when the CLI is not installed', function()
      local restore_exe = h.stub(vim.fn, 'executable', function() return 0 end)
      asyncapi.diff(0)
      restore_exe()
      assert.same({
        'asyncapi is not installed: `:MasonInstall asyncapi-cli`',
        vim.log.levels.ERROR,
      }, notes[1])
    end)

    it('says when the buffer holds no file', function()
      fake({ [[echo '[]']] })
      vim.api.nvim_set_current_buf(h.buffer({ lines = doc }))
      asyncapi.diff(0)
      assert.same(
        { 'This buffer holds no file', vim.log.levels.WARN },
        notes[1]
      )
    end)

    it('says when the document is not in git at the revision', function()
      fake({ [[echo '[]']] })
      h.write(dir .. '/new-asyncapi.yaml', doc)
      vim.cmd.edit(dir .. '/new-asyncapi.yaml')
      asyncapi.diff(0, 'HEAD')
      vim.wait(5000, function() return #notes > 0 end)
      assert.same(
        { 'new-asyncapi.yaml is not in git at HEAD', vim.log.levels.WARN },
        notes[1]
      )
      assert.is_nil(vim.uv.fs_stat(dir .. '/.asyncapi-base-new-asyncapi.yaml'))
    end)

    it('says when the CLI printed no JSON, or too much of it', function()
      fake({ 'echo garbage' })
      asyncapi.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same(
        { 'asyncapi diff failed: asyncapi exited 0', vim.log.levels.ERROR },
        notes[1]
      )

      local system = require('util.system')
      local restore_max = h.stub(system, 'MAX_BYTES', 1024)
      fake({ "yes '[{}]' | head -c 65536" })
      asyncapi.diff(0)
      vim.wait(5000, function() return #notes > 1 end)
      restore_max()
      assert.same({
        'asyncapi diff failed: more output than can be read',
        vim.log.levels.ERROR,
      }, notes[2])
    end)

    it('does nothing for a buffer wiped while the CLI ran', function()
      fake({ 'sleep 1', [[echo '[]']] })
      local bufnr = vim.api.nvim_get_current_buf()
      asyncapi.diff(bufnr)
      vim.wait(200)
      vim.cmd('bwipeout! ' .. bufnr)
      assert.is_false(vim.wait(3000, function() return #notes > 0 end))
      assert.is_nil(vim.uv.fs_stat(dir .. '/.asyncapi-base-asyncapi.yaml'))
    end)

    it('removes the copies it still holds when Neovim leaves', function()
      fake({ [[echo '[]']] })
      asyncapi.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      -- A copy a run has not removed yet, as when the CLI is still at work
      local left = dir .. '/.asyncapi-base-left.yaml'
      h.write(left, { 'copy' })
      asyncapi._leftover[left] = true
      -- A state file that is not JSON counts as empty
      h.write(asyncapi.STATE, { 'not json' })
      vim.api.nvim_exec_autocmds('VimLeavePre', { group = 'dy_asyncapi' })
      assert.is_nil(vim.uv.fs_stat(left))
      assert.same(
        {},
        vim.json.decode(table.concat(vim.fn.readfile(asyncapi.STATE)))
      )
    end)

    it('maps the diff on a document', function()
      local bufnr = vim.api.nvim_get_current_buf()
      asyncapi.attach(bufnr)
      local descs = vim.tbl_map(
        function(map) return map.desc end,
        vim.api.nvim_buf_get_keymap(bufnr, 'n')
      )
      assert.same({ 'Breaking Changes Since HEAD (AsyncAPI)' }, descs)
    end)
  end)
end)
