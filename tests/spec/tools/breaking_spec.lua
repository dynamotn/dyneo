local h = require('helpers')

describe('tools.breaking', function()
  local breaking

  before_each(function()
    h.unload('tools.breaking')
    breaking = require('tools.breaking')
  end)

  it('lets only a plain revision into the buf input', function()
    assert.is_true(breaking.safe_rev('HEAD~2'))
    assert.is_true(breaking.safe_rev('origin/main'))
    assert.is_false(breaking.safe_rev('HEAD,subdir=/etc'))
    assert.is_false(breaking.safe_rev('main#x'))
  end)

  it('runs buf from the repository on the module directory', function()
    local dir, cleanup = h.tmpdir()
    vim.fn.mkdir(dir .. '/.git', 'p')
    h.write(dir .. '/api/buf.yaml', { 'version: v2' })
    h.write(dir .. '/api/proto/user.proto', {})
    local run = assert(breaking.buf_cmd(dir .. '/api/proto/user.proto', 'HEAD'))
    assert.equals(dir, run.cwd)
    assert.same({
      'buf',
      'breaking',
      'api',
      '--against',
      '.git#ref=HEAD,subdir=api',
      '--error-format',
      'json',
    }, run.cmd)
    h.write(dir .. '/buf.yaml', {})
    h.write(dir .. '/root.proto', {})
    assert.same(
      '.git#ref=HEAD',
      breaking.buf_cmd(dir .. '/root.proto', 'HEAD').cmd[5]
    )
    local _, err = breaking.buf_cmd('/nowhere/x.proto', 'HEAD')
    assert.equals('No buf.yaml above this file', err)
    cleanup()
  end)

  it('reads the annotations buf prints, a line each', function()
    local items = breaking.buf_items(
      '{"path":"api/proto/user.proto","start_line":3,"start_column":1,'
        .. '"type":"FIELD_NO_DELETE","message":"Field 2 was deleted."}\n',
      '/r'
    )
    assert.same({
      {
        filename = '/r/api/proto/user.proto',
        lnum = 3,
        col = 1,
        type = 'E',
        text = 'Field 2 was deleted. [FIELD_NO_DELETE]',
      },
    }, items)
    assert.equals(
      '/r/api/a.proto',
      breaking.buf_items(
        '{"start_line":0,"type":"FILE_NO_DELETE","message":"gone"}',
        '/r',
        '/r/api/a.proto'
      )[1].filename
    )
    assert.same({}, breaking.buf_items('\n', '/r'))
    assert.is_nil(breaking.buf_items('Failure: no buf.yaml', '/r'))
  end)

  it(
    'reads the breaking lines of graphql-inspector',
    function()
      assert.same(
        {
          'Field User.name was removed from object type User',
          'Type Role was removed',
        },
        breaking.inspector_changes(table.concat({
          '[log] Detected the following changes (3) between schemas:',
          '[log] \27[31m✖\27[39m  Field User.name was removed from object type User',
          '[log] ✖  Type Role was removed',
          '[log] ⚠  Argument x added',
          '[error] Detected 2 breaking changes',
        }, '\n'))
      )
    end
  )

  it('finds the line a GraphQL change is about', function()
    local schema = {
      'type Query {',
      '  user(id: ID!): User',
      '}',
      'type User {',
      '  id: ID!',
      '  email: String',
      '}',
    }
    local files = { ['schema.graphql'] = schema }
    local function locate(message)
      return { breaking.graphql_locate(files, 'schema.graphql', message) }
    end
    assert.same(
      { 'schema.graphql', 6 },
      locate('Field User.email changed type')
    )
    assert.same(
      { 'schema.graphql', 4 },
      locate('Field User.name was removed from object type User')
    )
    assert.same({ 'schema.graphql', 1 }, locate('Type Role was removed'))
  end)

  describe('diff', function()
    local dir, cleanup, path, notes, restore, answer, asked, restore_confirm

    before_each(function()
      h.unload('util.trust')
      answer, asked = 1, 0
      restore_confirm = h.stub(vim.fn, 'confirm', function()
        asked = asked + 1
        return answer
      end)
      dir, cleanup = h.tmpdir()
      path = vim.env.PATH
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg, level) table.insert(notes, { msg, level }) end
      )
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
    end)
    after_each(function()
      restore()
      restore_confirm()
      vim.env.PATH = path
      vim.cmd('cclose | silent! %bwipeout!')
      cleanup()
    end)

    ---@param name string
    ---@param body string[]
    local function fake(name, body)
      h.write(dir .. '/bin/' .. name, vim.list_extend({ '#!/bin/sh' }, body))
      vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
      vim.env.PATH = dir .. '/bin:' .. path
    end

    it('refuses a Protobuf buffer that is not written', function()
      h.write(dir .. '/buf.yaml', {})
      vim.cmd.edit(dir .. '/a.proto')
      vim.bo.filetype = 'proto'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'syntax = "proto3";' })
      breaking.diff(0)
      assert.is_truthy(
        notes[1][1]:find('a%.proto first: buf compares the files on disk$')
      )
    end)

    it('refuses while another buffer of the module is not written', function()
      h.write(dir .. '/buf.yaml', {})
      h.write(dir .. '/a.proto', { 'syntax = "proto3";' })
      h.write(dir .. '/sub/b.proto', { 'syntax = "proto3";' })
      h.write(dir .. '-other/c.proto', {})
      local other = vim.fn.bufadd(dir .. '-other/c.proto')
      vim.fn.bufload(other)
      vim.api.nvim_buf_set_lines(other, 0, -1, false, { 'x' })
      local b = vim.fn.bufadd(dir .. '/sub/b.proto')
      vim.fn.bufload(b)
      vim.api.nvim_buf_set_lines(b, 0, -1, false, { 'message B {}' })
      vim.cmd.edit(dir .. '/a.proto')
      vim.bo.filetype = 'proto'
      fake('buf', { 'exit 0' })
      breaking.diff(0)
      assert.equals(1, #notes)
      assert.is_truthy(notes[1][1]:find('sub/b%.proto first: buf compares'))
      vim.fn.delete(dir .. '-other', 'rf')
    end)

    it('runs buf only in a module trusted to run its plugins', function()
      h.write(dir .. '/buf.yaml', { 'plugins:', '  - plugin: ./check.sh' })
      h.write(dir .. '/a.proto', { 'syntax = "proto3";' })
      vim.cmd.edit(dir .. '/a.proto')
      vim.bo.filetype = 'proto'
      fake('buf', { 'touch "$PWD/ran"', 'exit 0' })
      answer = 2
      breaking.diff(0)
      assert.same({
        'Not run: the module is not trusted to run its plugins',
        vim.log.levels.WARN,
      }, notes[1])
      vim.wait(200)
      assert.is_nil(vim.uv.fs_stat(dir .. '/ran'))
      answer = 1
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 1 end)
      assert.equals(2, asked)
      assert.is_not_nil(vim.uv.fs_stat(dir .. '/ran'))
    end)

    it('lists what buf finds, and fails loudly when it fails', function()
      h.write(dir .. '/buf.yaml', {})
      h.write(dir .. '/a.proto', { 'syntax = "proto3";' })
      vim.cmd.edit(dir .. '/a.proto')
      vim.bo.filetype = 'proto'
      fake('buf', {
        [[echo '{"path":"a.proto","start_line":1,"type":"FILE_NO_DELETE","message":"gone"}']],
        'exit 100',
      })
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same(
        { '1 breaking changes since HEAD (buf)', vim.log.levels.WARN },
        notes[1]
      )
      assert.equals(
        dir .. '/a.proto',
        vim.fn.bufname(vim.fn.getqflist()[1].bufnr)
      )
      fake('buf', { 'echo "Failure: bad ref" >&2', 'exit 1' })
      vim.cmd('cclose')
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 1 end)
      assert.same(
        { 'buf breaking failed: Failure: bad ref', vim.log.levels.ERROR },
        notes[2]
      )
    end)

    it('compares the GraphQL buffer as it is with git', function()
      h.write(
        dir .. '/schema.graphql',
        { 'type User {', '  name: String', '}' }
      )
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
      vim.cmd.edit(dir .. '/schema.graphql')
      vim.bo.filetype = 'graphql'
      vim.api.nvim_buf_set_lines(
        0,
        0,
        -1,
        false,
        { 'type User {', '  id: ID', '}' }
      )
      -- The old schema first, the buffer second
      fake('graphql-inspector', {
        'grep -q name $2 && grep -q id $3 || exit 9',
        'echo "[log] ✖  Field User.name was removed from object type User"',
        'exit 1',
      })
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same({
        '1 breaking changes since HEAD (graphql-inspector)',
        vim.log.levels.WARN,
      }, notes[1])
      assert.equals(1, vim.fn.getqflist()[1].lnum)
    end)

    it('says what it needs before comparing', function()
      vim.api.nvim_set_current_buf(h.buffer({ lines = { 'type A { x: ID }' } }))
      breaking.diff(0, 'HEAD; rm -rf /')
      breaking.diff(0)
      h.write(dir .. '/notes.md', { '# notes' })
      vim.cmd.edit(dir .. '/notes.md')
      breaking.diff(0)
      assert.same({
        { 'Not a revision: HEAD; rm -rf /', vim.log.levels.ERROR },
        { 'This buffer holds no file', vim.log.levels.WARN },
        {
          'Not a Protobuf or GraphQL file: `:DyOpenApiDiff` and `:DyAsyncApiDiff` compare the others',
          vim.log.levels.WARN,
        },
      }, notes)
    end)

    it('says when graphql-inspector is not installed', function()
      h.write(dir .. '/schema.graphql', { 'type User { id: ID }' })
      vim.cmd.edit(dir .. '/schema.graphql')
      vim.bo.filetype = 'graphql'
      local restore_exe = h.stub(vim.fn, 'executable', function() return 0 end)
      breaking.diff(0)
      restore_exe()
      assert.same({
        'graphql-inspector is not installed: `:MasonInstall graphql-inspector`',
        vim.log.levels.ERROR,
      }, notes[1])
    end)

    it('says when git holds no schema beside the buffer', function()
      h.write(dir .. '/schema.graphql', { 'type User { id: ID }' })
      vim.cmd.edit(dir .. '/schema.graphql')
      vim.bo.filetype = 'graphql'
      fake('graphql-inspector', { 'exit 0' })
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same({
        'No schema beside schema.graphql in git at HEAD',
        vim.log.levels.WARN,
      }, notes[1])
    end)

    it('says when graphql-inspector failed', function()
      h.write(dir .. '/schema.graphql', { 'type User { id: ID }' })
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
      vim.cmd.edit(dir .. '/schema.graphql')
      vim.bo.filetype = 'graphql'
      fake('graphql-inspector', { 'echo "cannot parse" >&2', 'exit 2' })
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same(
        { 'graphql-inspector failed: cannot parse', vim.log.levels.ERROR },
        notes[1]
      )
    end)

    it('maps the diff on a contract', function()
      local bufnr = h.buffer({ filetype = 'graphql' })
      breaking.attach(bufnr)
      local descs = vim.tbl_map(
        function(map) return map.desc end,
        vim.api.nvim_buf_get_keymap(bufnr, 'n')
      )
      assert.same({ 'Breaking Changes Since HEAD' }, descs)
    end)

    it('compares a schema split over files as one', function()
      h.write(dir .. '/api/a.graphql', { 'type Query {', '  user: User', '}' })
      h.write(dir .. '/api/b.graphql', {
        'type User {',
        '  id: ID',
        '  name: String',
        '}',
      })
      h.write(dir .. '/api/sub/c.graphql', { 'type Ignored { x: ID }' })
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
      h.write(dir .. '/api/b.graphql', { 'type User {', '  id: ID', '}' })
      vim.cmd.edit(dir .. '/api/a.graphql')
      vim.bo.filetype = 'graphql'
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        'type Query {',
        '  me: User',
        '}',
      })
      -- Both sides are every file beside the buffer, the buffer as it is
      fake('graphql-inspector', {
        'cat $2 > "$0.old"; cat $3 > "$0.new"',
        'echo "[log] ✖  Field name was removed from object type User"',
        'exit 1',
      })
      breaking.diff(0)
      vim.wait(5000, function() return #notes > 0 end)
      assert.same({
        '1 breaking changes since HEAD (graphql-inspector)',
        vim.log.levels.WARN,
      }, notes[1])
      local old =
        table.concat(vim.fn.readfile(dir .. '/bin/graphql-inspector.old'), '\n')
      local new =
        table.concat(vim.fn.readfile(dir .. '/bin/graphql-inspector.new'), '\n')
      assert.is_truthy(old:find('user: User', 1, true))
      assert.is_truthy(old:find('name: String', 1, true))
      assert.is_falsy(old:find('Ignored', 1, true))
      assert.is_truthy(new:find('me: User', 1, true))
      assert.is_falsy(new:find('name: String', 1, true))
      local item = vim.fn.getqflist()[1]
      assert.equals(dir .. '/api/b.graphql', vim.fn.bufname(item.bufnr))
      assert.equals(1, item.lnum)
    end)
  end)
end)
