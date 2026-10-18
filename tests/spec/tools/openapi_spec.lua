local h = require('helpers')

local YAML = {
  'openapi: 3.0.3',
  'servers:',
  '  - url: https://api.example.com/v1/',
  'paths:',
  '  /pets/{petId}:',
  '    parameters:',
  '      - $ref: "#/components/parameters/PetId"',
  '    get:',
  '      operationId: showPet',
  '      parameters:',
  '        - name: verbose',
  '          in: query',
  '          schema: { type: boolean }',
  '      responses:',
  '        "200":',
  '          description: ok',
  '    put:',
  '      requestBody:',
  '        content:',
  '          application/json:',
  '            schema:',
  '              $ref: "#/components/schemas/Pet"',
  'components:',
  '  parameters:',
  '    PetId:',
  '      name: petId',
  '      in: path',
  '      example: 7',
}

local DOC = {
  openapi = '3.0.3',
  servers = { { url = 'https://api.example.com/v1/' } },
  paths = {
    ['/pets/{petId}'] = {
      parameters = { { ['$ref'] = '#/components/parameters/PetId' } },
      get = {
        operationId = 'showPet',
        parameters = {
          { name = 'verbose', ['in'] = 'query', schema = { type = 'boolean' } },
          { name = 'X-Trace', ['in'] = 'header', example = 'abc' },
          { name = 'petId', ['in'] = 'path', example = 9 },
        },
      },
      put = {
        requestBody = {
          content = {
            ['application/json'] = {
              schema = { ['$ref'] = '#/components/schemas/Pet' },
            },
          },
        },
      },
    },
  },
  components = {
    parameters = {
      PetId = { name = 'petId', ['in'] = 'path', example = 7 },
    },
    schemas = {
      Pet = {
        type = 'object',
        properties = {
          name = { type = 'string' },
          born = { type = 'string', format = 'date' },
          tags = { type = 'array', items = { type = 'string', enum = { 'a' } } },
          owner = { ['$ref'] = '#/components/schemas/Owner' },
        },
      },
      Owner = {
        allOf = {
          { properties = { id = { type = 'integer' } } },
          { properties = { email = { type = 'string', format = 'email' } } },
        },
      },
      Loop = {
        properties = { next = { ['$ref'] = '#/components/schemas/Loop' } },
      },
    },
  },
}

describe('tools.openapi', function()
  local openapi

  before_each(function()
    h.unload('tools.openapi')
    openapi = require('tools.openapi')
  end)
  after_each(function() vim.cmd('silent! %bwipeout!') end)

  describe('operation_at', function()
    it('finds the method and path holding a line of YAML', function()
      assert.same(
        { path = '/pets/{petId}', method = 'get' },
        openapi.operation_at(YAML, 16)
      )
      assert.same(
        { path = '/pets/{petId}', method = 'get' },
        openapi.operation_at(YAML, 8)
      )
      assert.same(
        { path = '/pets/{petId}', method = 'put' },
        openapi.operation_at(YAML, 22)
      )
      -- On the path, or among its own parameters: no method yet
      assert.same({ path = '/pets/{petId}' }, openapi.operation_at(YAML, 7))
      assert.is_nil(openapi.operation_at(YAML, 28))
      assert.is_nil(openapi.operation_at(YAML, 1))
    end)

    it('takes the operation, not a property named like a method', function()
      local lines = {
        'paths:',
        '  /pets:',
        '    post:',
        '      requestBody:',
        '        content:',
        '          application/json:',
        '            schema:',
        '              properties:',
        '                delete:',
        '                  type: boolean',
      }
      assert.same(
        { path = '/pets', method = 'post' },
        openapi.operation_at(lines, 10)
      )
    end)

    it('finds them in pretty-printed JSON', function()
      local json = vim.split(
        [[{
  "paths": {
    "/users": {
      "post": {
        "summary": "add",
        "requestBody": {
        }
      }
    }
  }
}]],
        '\n'
      )
      assert.same(
        { path = '/users', method = 'post' },
        openapi.operation_at(json, 5)
      )
      assert.same(
        { path = '/users', method = 'post' },
        openapi.operation_at(json, 7)
      )
    end)
  end)

  it('follows local refs, and stops at a loop', function()
    assert.equals(
      'petId',
      openapi.resolve(DOC, { ['$ref'] = '#/components/parameters/PetId' }).name
    )
    local outside = { ['$ref'] = 'other.yaml#/x' }
    assert.equals(outside, openapi.resolve(DOC, outside))
    local loop = { ['$ref'] = '#/a' }
    assert.equals('table', type(openapi.resolve({ a = loop }, loop)))
    assert.equals(
      'table',
      type(openapi.example(DOC, DOC.components.schemas.Loop))
    )
  end)

  it('makes an example out of a schema', function()
    assert.same({
      name = 'string',
      born = '2026-01-01',
      tags = { 'a' },
      owner = { id = 0, email = 'user@example.com' },
    }, openapi.example(DOC, { ['$ref'] = '#/components/schemas/Pet' }))
    assert.equals(5, openapi.example(DOC, { type = 'integer', example = 5 }))
    assert.equals('x', openapi.example(DOC, { oneOf = { { enum = { 'x' } } } }))
  end)

  describe('request', function()
    it('takes the operation parameters over the path ones', function()
      local request =
        openapi.request(DOC, { path = '/pets/{petId}', method = 'get' })
      assert.equals('showPet', request.name)
      assert.equals('GET', request.method)
      assert.equals('https://api.example.com/v1', request.base)
      assert.equals('/pets/{{petId}}', request.path)
      assert.same({ { name = 'petId', value = '9' } }, request.vars)
      assert.same({ { name = 'verbose', value = 'false' } }, request.query)
      assert.same({ { name = 'X-Trace', value = 'abc' } }, request.headers)
      assert.is_nil(request.body)
    end)

    it('makes a JSON body, and names an unnamed operation', function()
      local request =
        openapi.request(DOC, { path = '/pets/{petId}', method = 'put' })
      assert.equals('PUT /pets/{petId}', request.name)
      assert.same({ { name = 'petId', value = '7' } }, request.vars)
      assert.equals('application/json', request.content_type)
      assert.same({
        name = 'string',
        born = '2026-01-01',
        tags = { 'a' },
        owner = { id = 0, email = 'user@example.com' },
      }, vim.json.decode(request.body))
    end)

    it(
      'takes the first method of a path when none is under the cursor',
      function()
        assert.equals(
          'GET',
          openapi.request(DOC, { path = '/pets/{petId}' }).method
        )
        assert.is_nil(openapi.request(DOC, { path = '/nope' }))
        assert.is_nil(
          openapi.request({ paths = { ['/x'] = {} } }, { path = '/x' })
        )
      end
    )
  end)

  it('keeps a variable on one line, and quotes it for the shell', function()
    local request = {
      name = 'x',
      method = 'GET',
      base = 'https://api.example.com',
      path = '/x',
      vars = {},
      query = {
        {
          name = 'q',
          value = openapi.request({
            paths = {
              ['/x'] = {
                get = {
                  parameters = {
                    { name = 'q', ['in'] = 'query', example = "a b\nit's" },
                  },
                },
              },
            },
          }, { path = '/x' }).query[1].value,
        },
      },
      headers = {},
    }
    assert.equals([[a b\nit's]], request.query[1].value)
    assert.equals("@q = a b\\nit's", openapi.http(request)[2])
    assert.equals(
      [[# hurl --variable baseUrl=https://api.example.com --variable 'q=a b\nit'\''s']],
      openapi.hurl(request)[2]
    )
    local bufnr = h.buffer()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, openapi.http(request))
  end)

  it('writes it for kulala and for Hurl', function()
    local request =
      openapi.request(DOC, { path = '/pets/{petId}', method = 'get' })
    assert.same({
      '@baseUrl = https://api.example.com/v1',
      '@petId = 9',
      '@verbose = false',
      '@X-Trace = abc',
      '',
      '### showPet',
      'GET {{baseUrl}}/pets/{{petId}}?verbose={{verbose}}',
      'X-Trace: {{X-Trace}}',
    }, openapi.http(request))
    assert.same({
      '# showPet',
      '# hurl --variable baseUrl=https://api.example.com/v1 --variable petId=9'
        .. ' --variable verbose=false --variable X-Trace=abc',
      'GET {{baseUrl}}/pets/{{petId}}',
      'X-Trace: {{X-Trace}}',
      '[QueryStringParams]',
      'verbose: {{verbose}}',
    }, openapi.hurl(request))

    local put = openapi.http(
      openapi.request(DOC, { path = '/pets/{petId}', method = 'put' })
    )
    -- The body comes after its type and a blank line
    local at = vim.fn.index(put, 'Content-Type: application/json') + 1
    assert.is_true(at > 0)
    assert.equals('', put[at + 1])
    assert.equals('{', put[at + 2])
  end)

  it('opens the request of the operation under the cursor', function()
    local bufnr = h.buffer({
      lines = vim.split(vim.json.encode(DOC), '\n'),
      filetype = 'json.openapi',
    })
    vim.api.nvim_set_current_buf(bufnr)
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    -- One line of JSON: the cursor is in no operation
    openapi.command({ fargs = { 'hurl' } })
    restore()
    assert.equals('The cursor is in no operation', notes[1])

    local pretty = vim.split(vim.json.encode(DOC, { indent = '  ' }), '\n')
    bufnr = h.buffer({ lines = pretty, filetype = 'json.openapi' })
    vim.api.nvim_set_current_buf(bufnr)
    local row
    for number, line in ipairs(pretty) do
      if line:find('"operationId"', 1, true) then row = number end
    end
    vim.api.nvim_win_set_cursor(0, { row, 0 })
    openapi.command({ fargs = { 'hurl' } })
    assert.equals('hurl', vim.bo.filetype)
    assert.equals('# showPet', vim.api.nvim_buf_get_lines(0, 0, 1, false)[1])
  end)

  describe('diff', function()
    it('finds the line of an operation, else of its path', function()
      assert.equals(8, openapi.line_of(YAML, '/pets/{petId}', 'GET'))
      assert.equals(17, openapi.line_of(YAML, '/pets/{petId}', 'put'))
      assert.equals(5, openapi.line_of(YAML, '/pets/{petId}', 'post'))
      assert.is_nil(openapi.line_of(YAML, '/nope', 'get'))
      assert.is_nil(openapi.line_of(YAML, nil, nil))
    end)

    it('puts each change on its operation, as loud as its level', function()
      local diagnostics = openapi.diff_diagnostics({
        {
          id = 'response-property-removed',
          text = 'removed the property name',
          level = 3,
          operation = 'GET',
          path = '/pets/{petId}',
        },
        { id = 'api-path-removed', level = 2, path = '/gone' },
        { text = 'a note', level = 1 },
      }, YAML)
      assert.same({
        lnum = 7,
        col = 0,
        severity = vim.diagnostic.severity.ERROR,
        message = 'removed the property name',
        code = 'response-property-removed',
        source = 'oasdiff',
      }, diagnostics[1])
      assert.equals(0, diagnostics[2].lnum)
      assert.equals('api-path-removed', diagnostics[2].message)
      assert.equals(vim.diagnostic.severity.INFO, diagnostics[3].severity)
    end)

    it('leaves a file already named like its copies alone', function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/openapi.yaml', YAML)
      h.write(dir .. '/.oasdiff-base-openapi.yaml', { 'mine' })
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      openapi.compare(0, 'HEAD', dir .. '/openapi.yaml', 'old', {}, false)
      restore()
      assert.same(
        { 'mine' },
        vim.fn.readfile(dir .. '/.oasdiff-base-openapi.yaml')
      )
      assert.equals(
        '.oasdiff-base-openapi.yaml is in the way: not written over',
        notes[1]
      )
      cleanup()
    end)

    it('keeps the FileType hook of plugin/openapi.lua', function()
      vim.cmd('runtime plugin/openapi.lua')
      local hooks = { group = 'dy_openapi', event = 'FileType' }
      local before = #vim.api.nvim_get_autocmds(hooks)
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/openapi.yaml', YAML)
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/no-bin'
      local restore = h.stub(vim, 'notify', function() end)
      openapi.compare(0, 'HEAD', dir .. '/openapi.yaml', 'old', { 'new' }, true)
      restore()
      vim.env.PATH = path
      cleanup()
      assert.is_true(before > 0)
      assert.equals(before, #vim.api.nvim_get_autocmds(hooks))
    end)

    it('removes its copies when oasdiff cannot start', function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/openapi.yaml', YAML)
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/no-bin'
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      openapi.compare(0, 'HEAD', dir .. '/openapi.yaml', 'old', { 'new' }, true)
      restore()
      vim.env.PATH = path
      assert.equals('oasdiff could not run', notes[1])
      assert.same({}, vim.fn.glob(dir .. '/.oasdiff-*', true, true))
      cleanup()
    end)

    it('compares the buffer with the spec at a revision', function()
      local dir, cleanup = h.tmpdir()
      local function git(...)
        local result = vim
          .system(
            vim.list_extend(
              { 'git', '-c', 'user.name=t', '-c', 'user.email=t@t' },
              { ... }
            ),
            { cwd = dir }
          )
          :wait()
        assert.equals(0, result.code, result.stderr)
      end
      git('init', '-q')
      h.write(dir .. '/openapi.yaml', YAML)
      git('add', 'openapi.yaml')
      git('commit', '-q', '-m', 'spec')
      vim.fn.mkdir(dir .. '/bin', 'p')
      -- An oasdiff that keeps what it compared, and finds one break
      h.write(dir .. '/bin/oasdiff', {
        '#!/bin/sh',
        'echo "$@" > "' .. dir .. '/args"',
        'cp "$2" "' .. dir .. '/base.seen"',
        'cp "$3" "' .. dir .. '/revision.seen"',
        [[echo '[{"id":"x","text":"broke","level":3,"operation":"PUT","path":"/pets/{petId}"}]']],
      })
      vim.fn.setfperm(dir .. '/bin/oasdiff', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      local notes = {}
      local restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )

      vim.cmd.edit(dir .. '/openapi.yaml')
      local bufnr = vim.api.nvim_get_current_buf()
      vim.api.nvim_buf_set_lines(bufnr, 0, 1, false, { 'openapi: 3.1.0' })
      openapi.diff(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
      restore()
      vim.env.PATH = path

      assert.equals('1 changes since HEAD', notes[1])
      local diagnostics = vim.diagnostic.get(bufnr)
      assert.equals(1, #diagnostics)
      assert.equals(16, diagnostics[1].lnum)
      -- The base is the committed spec, the revision the unsaved buffer
      assert.equals('openapi: 3.0.3', vim.fn.readfile(dir .. '/base.seen')[1])
      assert.equals(
        'openapi: 3.1.0',
        vim.fn.readfile(dir .. '/revision.seen')[1]
      )
      assert.is_truthy(
        vim.fn.readfile(dir .. '/args')[1]:find('--format json', 1, true)
      )
      -- And the copies are gone
      local base = vim.fn.readfile(dir .. '/args')[1]:match('breaking (%S+)')
      assert.equals(0, vim.fn.filereadable(base))
      -- Beside the document, so a relative `$ref` resolves
      assert.equals(dir, vim.fs.dirname(base))

      -- A failed run is an error, never an all-clear
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
      h.write(dir .. '/bin/oasdiff', {
        '#!/bin/sh',
        'echo "failed to load base spec: ./pet.yaml not found" >&2',
        'exit 1',
      })
      vim.env.PATH = dir .. '/bin:' .. path
      openapi.diff(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
      restore()
      vim.env.PATH = path
      assert.equals(
        'oasdiff failed: failed to load base spec: ./pet.yaml not found',
        notes[1]
      )
      assert.same({}, vim.fn.glob(dir .. '/.oasdiff-*', true, true))
      vim.diagnostic.reset()
      cleanup()
    end)
  end)

  it('finds no operation where the keys hold none', function()
    assert.is_nil(openapi.operation_at({ 'openapi: 3.0.3', 'info:' }, 2))
    -- Nothing at the top level: the keys run out before a path does
    assert.is_nil(openapi.operation_at({ '  a:', '    b:' }, 2))
  end)

  it(
    'takes the first of the examples, and nothing of an unknown type',
    function()
      assert.equals('ex', openapi.example(DOC, { examples = { 'ex' } }))
      assert.equals(vim.NIL, openapi.example(DOC, { type = 'null' }))
    end
  )

  it('takes the body from the named examples of the request', function()
    local doc = vim.deepcopy(DOC)
    doc.paths['/pets/{petId}'].put.requestBody.content['application/json'] = {
      examples = { one = { value = { name = 'Rex' } } },
    }
    local request =
      openapi.request(doc, { path = '/pets/{petId}', method = 'put' })
    assert.is_truthy(request.body:find('"name": "Rex"', 1, true))
    local hurl = openapi.hurl(request)
    assert.is_true(vim.list_contains(hurl, 'Content-Type: application/json'))
    assert.equals('}', hurl[#hurl])
  end)

  it('refuses a kind of request it does not write', function()
    local notes = {}
    local restore = h.stub(
      vim,
      'notify',
      function(msg) table.insert(notes, msg) end
    )
    openapi.command({ fargs = { 'nope' } })
    restore()
    assert.same({ 'Unknown kind: nope' }, notes)
  end)

  describe('decode', function()
    it('says when the buffer is not JSON', function()
      local bufnr = h.buffer({ lines = { 'nope' }, filetype = 'json' })
      local doc, err
      openapi.decode(bufnr, function(d, e)
        doc, err = d, e
      end)
      assert.is_nil(doc)
      assert.equals('Not a JSON document', err)
    end)

    it('needs yq for YAML, and says when yq could not read it', function()
      local bufnr = h.buffer({ lines = { 'a: [' }, filetype = 'yaml' })
      local restore = h.stub(vim.fn, 'executable', function() return 0 end)
      local doc, err
      openapi.decode(bufnr, function(d, e)
        doc, err = d, e
      end)
      restore()
      assert.is_nil(doc)
      assert.equals('yq is needed to read an OpenAPI document in YAML', err)

      local dir, cleanup = h.tmpdir()
      h.write(
        dir .. '/bin/yq',
        { '#!/bin/sh', 'echo "bad yaml" >&2', 'exit 1' }
      )
      vim.fn.setfperm(dir .. '/bin/yq', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      err = nil
      openapi.decode(bufnr, function(d, e)
        doc, err = d, e
      end)
      assert.is_true(vim.wait(5000, function() return err ~= nil end, 10))
      vim.env.PATH = path
      cleanup()
      assert.equals('yq could not read it: bad yaml', err)
    end)
  end)

  describe('diff before the spec is read', function()
    local notes, restore

    before_each(function()
      notes = {}
      restore = h.stub(
        vim,
        'notify',
        function(msg) table.insert(notes, msg) end
      )
    end)
    after_each(function() restore() end)

    it('needs oasdiff, and a file', function()
      local restore_exe = h.stub(vim.fn, 'executable', function() return 0 end)
      openapi.diff(0)
      restore_exe()
      restore_exe = h.stub(vim.fn, 'executable', function() return 1 end)
      vim.api.nvim_set_current_buf(h.buffer({ lines = YAML }))
      openapi.diff(0)
      restore_exe()
      assert.same(
        { 'oasdiff is not installed', 'This buffer holds no file' },
        notes
      )
    end)

    it('says when git could not run', function()
      local restore_exe = h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'git' and 0 or 1 end
      )
      local bufnr = h.buffer({ name = '/tmp/x/openapi.yaml', lines = YAML })
      openapi.diff(bufnr)
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
      restore_exe()
      assert.same({ 'git could not run' }, notes)
    end)

    it('says when the spec is not in git at the revision', function()
      local dir, cleanup = h.tmpdir()
      vim.system({ 'git', 'init', '-q' }, { cwd = dir }):wait()
      h.write(dir .. '/openapi.yaml', YAML)
      local restore_exe = h.stub(
        vim.fn,
        'executable',
        function(name) return name == 'oasdiff' and 1 or 0 end
      )
      vim.cmd.edit(dir .. '/openapi.yaml')
      openapi.diff(0)
      restore_exe()
      restore_exe = h.stub(vim.fn, 'executable', function() return 1 end)
      openapi.diff(0, 'HEAD')
      assert.is_true(vim.wait(5000, function() return #notes > 1 end, 10))
      restore_exe()
      cleanup()
      assert.same(
        { 'git could not run', 'openapi.yaml is not in git at HEAD' },
        notes
      )
    end)

    it('removes the copies it still holds when Neovim leaves', function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/openapi.yaml', YAML)
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/no-bin'
      openapi.compare(0, 'HEAD', dir .. '/openapi.yaml', 'old', { 'new' }, true)
      vim.env.PATH = path
      local left = dir .. '/.oasdiff-base-left.yaml'
      h.write(left, { 'copy' })
      openapi._leftover[left] = true
      vim.api.nvim_exec_autocmds(
        'VimLeavePre',
        { group = 'dy_openapi_leftover' }
      )
      assert.is_nil(vim.uv.fs_stat(left))
      cleanup()
    end)

    it('says when oasdiff printed something that is not JSON', function()
      local dir, cleanup = h.tmpdir()
      h.write(dir .. '/openapi.yaml', YAML)
      h.write(dir .. '/bin/oasdiff', { '#!/bin/sh', 'echo garbage' })
      vim.fn.setfperm(dir .. '/bin/oasdiff', 'rwxr-xr-x')
      local path = vim.env.PATH
      vim.env.PATH = dir .. '/bin:' .. path
      vim.cmd.edit(dir .. '/openapi.yaml')
      openapi.compare(
        vim.api.nvim_get_current_buf(),
        'HEAD',
        dir .. '/openapi.yaml',
        'old',
        YAML,
        false
      )
      assert.is_true(vim.wait(5000, function() return #notes > 0 end, 10))
      vim.env.PATH = path
      cleanup()
      assert.same({ 'oasdiff printed something that is not JSON' }, notes)
    end)
  end)

  it('reads YAML through yq', function()
    if vim.fn.executable('yq') ~= 1 then
      assert(not vim.env.CI, 'no yq on CI')
      return pending('yq is not installed')
    end
    local bufnr = h.buffer({ lines = YAML, filetype = 'yaml.openapi' })
    local doc, err, done
    openapi.decode(bufnr, function(d, e)
      doc, err, done = d, e, true
    end)
    -- yq runs off the main loop
    assert.is_nil(done)
    assert.is_true(vim.wait(5000, function() return done end, 10))
    assert.is_nil(err)
    assert.equals('showPet', doc.paths['/pets/{petId}'].get.operationId)
  end)
end)
