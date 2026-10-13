local h = require('helpers')

local CRDS_CATALOG =
  'https://raw.githubusercontent.com/datreeio/CRDs-catalog/main'
local KUBERNETES_SCHEMAS =
  'https://raw.githubusercontent.com/yannh/kubernetes-json-schema/master'
local CLOUD_INIT =
  'https://raw.githubusercontent.com/canonical/cloud-init/main/cloudinit/config/schemas/schema-cloud-config-v1.json'
local MODELINE = '# yaml-language-server: $schema='

local STORE_SCHEMAS = {
  {
    name = 'GitHub Workflow',
    description = 'A workflow',
    url = 'https://json.schemastore.org/github-workflow.json',
    fileMatch = { '**/.github/workflows/*.yml' },
  },
  {
    name = 'Docker Compose',
    url = 'https://json.schemastore.org/compose.json',
    fileMatch = 'docker-compose.yml',
  },
}

describe('util.yaml_schema', function()
  local yaml_schema, dir, cleanup, stubs, clients, notified, deferred

  local function stub(tbl, key, value)
    table.insert(stubs, h.stub(tbl, key, value))
  end

  --- A stand-in for the yamlls client, answering requests from `responses`
  local function fake_client(opts)
    opts = opts or {}
    local client = {
      id = opts.id or (#clients + 1),
      name = opts.name or 'yamlls',
      settings = opts.settings or {},
      root_dir = opts.root_dir,
      buffers = opts.buffers or {},
      responses = opts.responses or {},
      sent = {},
      requests = {},
    }
    function client:notify(method, params)
      table.insert(self.sent, { method = method, params = params })
    end
    function client:request(method, params, handler, bufnr)
      table.insert(
        self.requests,
        { method = method, params = params, bufnr = bufnr }
      )
      local response = self.responses[method]
      if type(response) == 'function' then return handler(response(params)) end
      handler(nil, response)
    end
    table.insert(clients, client)
    return client
  end

  local function sent(client, method)
    return vim.tbl_filter(
      function(s) return s.method == method end,
      client.sent
    )
  end

  --- A named buffer shown in the current window, holding `lines`
  local function open(name, lines, filetype)
    local bufnr = h.buffer({
      name = name,
      lines = lines,
      filetype = filetype or 'yaml',
    })
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  local function lines_of(bufnr)
    return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end

  local function cache_file()
    return vim.fs.joinpath(
      dir,
      'cache',
      vim.env.NVIM_APPNAME or 'nvim',
      'yaml-schema',
      'crds-catalog.json'
    )
  end

  before_each(function()
    dir, cleanup = h.tmpdir()
    stubs, clients, notified, deferred = {}, {}, {}, {}
    -- The CRDs cache path is worked out as the module loads
    local cache_home = vim.env.XDG_CACHE_HOME
    vim.env.XDG_CACHE_HOME = vim.fs.joinpath(dir, 'cache')
    table.insert(stubs, function() vim.env.XDG_CACHE_HOME = cache_home end)
    stub(
      vim,
      'notify',
      function(msg, level) table.insert(notified, { msg = msg, level = level }) end
    )
    stub(
      vim,
      'defer_fn',
      function(fn, timeout)
        table.insert(deferred, { fn = fn, timeout = timeout })
      end
    )
    stub(vim.lsp, 'get_clients', function(filter)
      filter = filter or {}
      return vim.tbl_filter(
        function(c)
          return (not filter.name or c.name == filter.name)
            and (not filter.bufnr or c.buffers[filter.bufnr] == true)
        end,
        clients
      )
    end)
    package.loaded['schemastore'] = {
      json = { load = function() return { schemas = STORE_SCHEMAS } end },
      yaml = {
        schemas = function() return { ['https://x/s.json'] = { '*.y' } } end,
      },
    }
    package.loaded['lualine'] = nil
    package.loaded['snacks'] = nil
    DyNeo.yaml_schema_dirs = nil
    h.unload('util.yaml_schema')
    yaml_schema = require('util.yaml_schema')
  end)

  after_each(function()
    for i = #stubs, 1, -1 do
      stubs[i]()
    end
    package.loaded['schemastore'] = nil
    package.loaded['snacks'] = nil
    _G.Snacks = nil
    DyNeo.yaml_schema_dirs = nil
    pcall(vim.api.nvim_clear_autocmds, { group = 'util.yaml_schema' })
    cleanup()
  end)

  describe('get_name', function()
    it(
      'names the Kubernetes keyword',
      function()
        assert.are.equal('Kubernetes', yaml_schema.get_name('kubernetes'))
      end
    )

    it(
      'names cloud-init',
      function()
        assert.are.equal('cloud-init', yaml_schema.get_name(CLOUD_INIT))
      end
    )

    it('names a local file after its base name', function()
      assert.are.equal('a.json', yaml_schema.get_name('/some/where/a.json'))
      assert.are.equal('b.yaml', yaml_schema.get_name('file:///x/y/b.yaml'))
    end)

    it(
      'takes the name SchemaStore gives a URL',
      function()
        assert.are.equal(
          'GitHub Workflow',
          yaml_schema.get_name(
            'https://json.schemastore.org/github-workflow.json'
          )
        )
      end
    )

    it('names a kubernetes-json-schema file after its kind', function()
      assert.are.equal(
        'Kubernetes deployment-apps-v1',
        yaml_schema.get_name(
          KUBERNETES_SCHEMAS
            .. '/master-standalone-strict/deployment-apps-v1.json'
        )
      )
      assert.are.equal(
        'Kubernetes',
        yaml_schema.get_name(
          KUBERNETES_SCHEMAS .. '/v1.29-standalone-strict/all.json'
        )
      )
    end)

    it(
      'names a CRDs catalog schema after kind, group and version',
      function()
        assert.are.equal(
          'certificate (cert-manager.io/v1)',
          yaml_schema.get_name(
            CRDS_CATALOG .. '/cert-manager.io/certificate_v1.json'
          )
        )
      end
    )

    it('falls back on the title, then on Custom', function()
      assert.are.equal(
        'Mine',
        yaml_schema.get_name('https://e.x/s.json', 'Mine')
      )
      assert.are.equal('Custom', yaml_schema.get_name('https://e.x/s.json'))
    end)

    it('copes without SchemaStore', function()
      package.loaded['schemastore'] = nil
      h.unload('util.yaml_schema')
      stub(
        package.preload,
        'schemastore',
        function() error('not installed') end
      )
      yaml_schema = require('util.yaml_schema')
      assert.are.equal(
        'Custom',
        yaml_schema.get_name('https://json.schemastore.org/compose.json')
      )
    end)
  end)

  describe('matchers', function()
    local function matcher(name)
      for _, m in ipairs(yaml_schema.matchers) do
        if m.name == name then return m end
      end
    end

    it('tries cloud-init, then Kubernetes, then Sigma', function()
      assert.are.same(
        { 'cloud-init', 'Kubernetes', 'Sigma' },
        vim.tbl_map(function(m) return m.name end, yaml_schema.matchers)
      )
      assert.are.equal(CLOUD_INIT, matcher('cloud-init').uri)
      assert.are.equal('kubernetes', matcher('Kubernetes').uri)
    end)

    it('knows cloud-init by its first line only', function()
      local m = matcher('cloud-init')
      assert.is_truthy(m.match({ '#cloud-config', 'users: []' }))
      assert.is_falsy(m.match({ '', '#cloud-config' }))
      assert.is_falsy(m.match({}))
    end)

    it('knows Kubernetes by a top-level apiVersion and kind', function()
      local m = matcher('Kubernetes')
      assert.is_true(m.match({ 'kind: Pod', 'metadata: {}', 'apiVersion: v1' }))
      assert.is_false(m.match({ 'apiVersion: v1' }))
      assert.is_false(m.match({ '  apiVersion: v1', '  kind: Pod' }))
      assert.is_false(m.match({ 'apiVersion:', 'kind:' }))
      assert.is_false(m.match({}))
    end)

    it('knows a Sigma rule by a top-level logsource and detection', function()
      local m = matcher('Sigma')
      assert.is_true(m.match({
        'title: Whoami',
        'logsource:',
        '  category: process_creation',
        'detection:',
        '  selection: {}',
      }))
      assert.is_false(m.match({ 'logsource:', '  detection: {}' }))
      assert.is_false(m.match({ 'detection:' }))
      assert.matches('sigma%-detection%-rule', m.uri)
    end)
  end)

  describe('set', function()
    it('warns when no yamlls is attached', function()
      local bufnr = open(dir .. '/a.yaml', {})
      yaml_schema.set(bufnr, { uri = 'kubernetes', name = 'Kubernetes' })
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
    end)

    it('warns for a buffer without a file', function()
      local bufnr = h.buffer()
      fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.set(bufnr, { uri = 'kubernetes', name = 'Kubernetes' })
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)

    it('points yaml.schemas at the schema for this file only', function()
      local path = dir .. '/a.yaml'
      local bufnr = open(path, {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.set(0, { uri = 'https://e.x/s.json', name = 'S' })
      assert.are.same(
        { path },
        client.settings.yaml.schemas['https://e.x/s.json']
      )
      assert.are.same({
        uri = 'https://e.x/s.json',
        name = 'S',
        auto = false,
        pattern = path,
      }, vim.b[bufnr].yaml_schema_choice)
      local notes = sent(client, 'workspace/didChangeConfiguration')
      assert.are.equal(1, #notes)
      assert.are.equal(client.settings, notes[1].params.settings)
      assert.are.equal('S', vim.b[bufnr].yaml_schema_name)
      assert.are.equal(1500, deferred[1].timeout)
    end)

    it('records a choice made by detection as automatic', function()
      local bufnr = open(dir .. '/a.yaml', {})
      fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.set(bufnr, { uri = 'kubernetes', name = 'Kubernetes' }, true)
      assert.is_true(vim.b[bufnr].yaml_schema_choice.auto)
      assert.are.equal('Kubernetes', vim.b[bufnr].yaml_schema_name)
    end)

    it('escapes glob characters in the file name', function()
      local path = dir .. '/[a]{b}(c)*?!+@.yaml'
      local bufnr = open(path, {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      assert.are.equal(
        dir .. '/\\[a\\]\\{b\\}\\(c\\)\\*\\?\\!\\+\\@.yaml',
        client.settings.yaml.schemas.u[1]
      )
    end)

    it('adds to the patterns the schema already has', function()
      local path = dir .. '/a.yaml'
      local bufnr = open(path, {})
      local client = fake_client({
        buffers = { [bufnr] = true },
        settings = { yaml = { schemas = { u = '*.k8s.yaml' } } },
      })
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      assert.are.same({ '*.k8s.yaml', path }, client.settings.yaml.schemas.u)
    end)

    it('replaces the schema set before for the buffer', function()
      local path = dir .. '/a.yaml'
      local bufnr = open(path, {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.set(bufnr, { uri = 'one', name = 'One' })
      yaml_schema.set(bufnr, { uri = 'two', name = 'Two' })
      assert.is_nil(client.settings.yaml.schemas.one)
      assert.are.same({ path }, client.settings.yaml.schemas.two)
      assert.are.equal('two', vim.b[bufnr].yaml_schema_choice.uri)
    end)

    it('refreshes the name once the server had time', function()
      local bufnr = open(dir .. '/a.yaml', {})
      local client = fake_client({
        buffers = { [bufnr] = true },
        responses = { ['yaml/get/jsonSchema'] = { { uri = CLOUD_INIT } } },
      })
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      deferred[1].fn()
      assert.are.equal('cloud-init', vim.b[bufnr].yaml_schema_name)
      assert.are.equal('yaml/get/jsonSchema', client.requests[1].method)
    end)
  end)

  describe('reset', function()
    it('does nothing without a choice', function()
      local bufnr = open(dir .. '/a.yaml', {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.reset(bufnr)
      assert.are.same({}, client.sent)
    end)

    it('drops the pattern of the buffer and keeps the others', function()
      local path = dir .. '/a.yaml'
      local bufnr = open(path, {})
      local client = fake_client({
        buffers = { [bufnr] = true },
        settings = { yaml = { schemas = { u = { '*.x.yaml' } } } },
      })
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      client.sent = {}
      yaml_schema.reset(0)
      assert.are.same({ '*.x.yaml' }, client.settings.yaml.schemas.u)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
      assert.is_nil(vim.b[bufnr].yaml_schema_name)
      assert.are.equal(1, #sent(client, 'workspace/didChangeConfiguration'))
    end)

    it('removes the schema once no pattern is left', function()
      local bufnr = open(dir .. '/a.yaml', {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      yaml_schema.reset(bufnr)
      assert.is_nil(client.settings.yaml.schemas.u)
    end)

    it('removes a pattern held as a plain string', function()
      local path = dir .. '/a.yaml'
      local bufnr = open(path, {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      vim.b[bufnr].yaml_schema_choice =
        { uri = 'u', name = 'U', auto = false, pattern = path }
      client.settings = { yaml = { schemas = { u = path, v = 'other' } } }
      yaml_schema.reset(bufnr)
      assert.are.same({ v = 'other' }, client.settings.yaml.schemas)
    end)

    it('tells every yamlls, and nobody when silent', function()
      local bufnr = open(dir .. '/a.yaml', {})
      local a = fake_client({ buffers = { [bufnr] = true } })
      local b = fake_client()
      local other = fake_client({ name = 'jsonls' })
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      vim.b[bufnr].yaml_schema_name = 'U'
      a.sent = {}
      yaml_schema.reset(bufnr, true)
      assert.are.same({}, a.sent)
      assert.are.equal('U', vim.b[bufnr].yaml_schema_name)

      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      a.sent = {}
      yaml_schema.reset(bufnr)
      assert.are.equal(1, #a.sent)
      assert.are.equal(1, #b.sent)
      assert.are.same({}, other.sent)
    end)
  end)

  describe('detect', function()
    local k8s = { 'apiVersion: v1', 'kind: Pod' }

    local function attached(bufnr, schemas)
      return fake_client({
        buffers = { [bufnr] = true },
        responses = { ['yaml/get/jsonSchema'] = schemas or {} },
      })
    end

    it('does nothing without yamlls', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      yaml_schema.detect(bufnr)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
    end)

    it('sets the matched schema when the server has none', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      local client = attached(bufnr)
      yaml_schema.detect(bufnr)
      assert.are.equal('yaml/get/jsonSchema', client.requests[1].method)
      assert.are.same({ vim.uri_from_bufnr(bufnr) }, client.requests[1].params)
      local choice = vim.b[bufnr].yaml_schema_choice
      assert.are.equal('kubernetes', choice.uri)
      assert.is_true(choice.auto)
    end)

    it('detects cloud-init', function()
      local bufnr = open(dir .. '/user-data.yaml', { '#cloud-config' })
      attached(bufnr)
      yaml_schema.detect(bufnr)
      assert.are.equal(CLOUD_INIT, vim.b[bufnr].yaml_schema_choice.uri)
    end)

    it('leaves a buffer the server already has a schema for', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      attached(bufnr, { { uri = 'https://e.x/s.json' } })
      yaml_schema.detect(bufnr)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
    end)

    it('leaves the buffer when the request fails', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      local client = attached(bufnr)
      client.responses['yaml/get/jsonSchema'] = function() return 'boom' end
      yaml_schema.detect(bufnr)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
    end)

    it('only looks at the plain yaml filetype', function()
      local bufnr = open(dir .. '/compose.yaml', k8s, 'yaml.docker-compose')
      local client = attached(bufnr)
      yaml_schema.detect(bufnr)
      assert.are.same({}, client.requests)
    end)

    it('never overrides a schema the user chose', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      local client = attached(bufnr)
      yaml_schema.set(bufnr, { uri = 'u', name = 'U' })
      yaml_schema.detect(bufnr)
      assert.are.equal('u', vim.b[bufnr].yaml_schema_choice.uri)
      assert.are.same({}, client.requests)
    end)

    it('keeps a detected schema that still matches', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      local client = attached(bufnr)
      yaml_schema.detect(bufnr)
      client.requests = {}
      yaml_schema.detect(bufnr)
      assert.are.same({}, client.requests)
      assert.are.equal('kubernetes', vim.b[bufnr].yaml_schema_choice.uri)
    end)

    it('drops a detected schema the content no longer matches', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      local client = attached(bufnr)
      yaml_schema.detect(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { 'foo: bar' })
      yaml_schema.detect(bufnr)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
      assert.is_nil(client.settings.yaml.schemas.kubernetes)
    end)

    it('switches a detected schema to the one that matches now', function()
      local bufnr = open(dir .. '/a.yaml', k8s)
      attached(bufnr)
      yaml_schema.detect(bufnr)
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '#cloud-config' })
      yaml_schema.detect(bufnr)
      assert.are.equal(CLOUD_INIT, vim.b[bufnr].yaml_schema_choice.uri)
    end)
  end)

  describe('insert_modeline', function()
    local function at(bufnr, row) vim.api.nvim_win_set_cursor(0, { row, 0 }) end

    it('writes the modeline at the top of a single document', function()
      local bufnr = open(dir .. '/a.yaml', { 'foo: 1', 'bar: 2' })
      at(bufnr, 2)
      yaml_schema.insert_modeline(0, { uri = 'https://e.x/s.json' })
      assert.are.same(
        { MODELINE .. 'https://e.x/s.json', 'foo: 1', 'bar: 2' },
        lines_of(bufnr)
      )
    end)

    it('replaces a modeline among the opening comments', function()
      local bufnr = open(dir .. '/a.yaml', {
        '# a comment',
        '  #  yaml-language-server: $schema=old.json',
        'foo: 1',
      })
      at(bufnr, 3)
      yaml_schema.insert_modeline(bufnr, { uri = 'https://e.x/new.json' })
      assert.are.same({
        '# a comment',
        MODELINE .. 'https://e.x/new.json',
        'foo: 1',
      }, lines_of(bufnr))
    end)

    it('does not take a modeline below the content for its own', function()
      local bufnr = open(dir .. '/a.yaml', {
        'foo: 1',
        '# yaml-language-server: $schema=old.json',
      })
      at(bufnr, 1)
      yaml_schema.insert_modeline(bufnr, { uri = 'n.json' })
      assert.are.same({
        MODELINE .. 'n.json',
        'foo: 1',
        '# yaml-language-server: $schema=old.json',
      }, lines_of(bufnr))
    end)

    it('writes into the document under the cursor', function()
      local bufnr = open(dir .. '/a.yaml', {
        'a: 1',
        '--- # second',
        'b: 2',
        '----',
        'c: 3',
        '---',
        'd: 4',
      })
      at(bufnr, 5)
      yaml_schema.insert_modeline(bufnr, { uri = 's.json' })
      assert.are.same({
        'a: 1',
        '--- # second',
        MODELINE .. 's.json',
        'b: 2',
        '----',
        'c: 3',
        '---',
        'd: 4',
      }, lines_of(bufnr))
    end)

    describe('for Kubernetes', function()
      local count = 0
      local function k8s_uri(lines, row, settings)
        count = count + 1
        local bufnr = open(dir .. '/k8s' .. count .. '.yaml', lines)
        fake_client({ buffers = { [bufnr] = true }, settings = settings or {} })
        at(bufnr, row or 1)
        yaml_schema.insert_modeline(bufnr, { uri = 'kubernetes' })
        for _, line in ipairs(lines_of(bufnr)) do
          if vim.startswith(line, MODELINE) then
            return line:sub(#MODELINE + 1)
          end
        end
      end

      it(
        'picks a core kind from kubernetes-json-schema',
        function()
          assert.are.equal(
            KUBERNETES_SCHEMAS .. '/master-standalone-strict/pod-v1.json',
            k8s_uri({ 'apiVersion: v1', 'kind: Pod' })
          )
        end
      )

      it('names the group of a built-in kind', function()
        assert.are.equal(
          KUBERNETES_SCHEMAS
            .. '/master-standalone-strict/deployment-apps-v1.json',
          k8s_uri({ 'kind: "Deployment" # c', "apiVersion: 'apps/v1'" })
        )
        assert.are.equal(
          KUBERNETES_SCHEMAS
            .. '/master-standalone-strict/ingress-networking-v1.json',
          k8s_uri({ 'apiVersion: networking.k8s.io/v1', 'kind: Ingress' })
        )
      end)

      it('follows the Kubernetes version yamlls is set to', function()
        for _, version in ipairs({ '1.29.0', 'v1.29.0' }) do
          assert.are.equal(
            KUBERNETES_SCHEMAS .. '/v1.29.0-standalone-strict/pod-v1.json',
            k8s_uri(
              { 'apiVersion: v1', 'kind: Pod' },
              1,
              { yaml = { kubernetesVersion = version } }
            )
          )
        end
      end)

      it(
        'takes a CRD from the catalog',
        function()
          assert.are.equal(
            CRDS_CATALOG .. '/cert-manager.io/certificate_v1.json',
            k8s_uri({ 'apiVersion: cert-manager.io/v1', 'kind: Certificate' })
          )
        end
      )

      it('reads the kind of the document under the cursor', function()
        local uri = k8s_uri({
          'apiVersion: v1',
          'kind: Pod',
          '---',
          'apiVersion: v1',
          'kind: Service',
        }, 5)
        assert.are.equal(
          KUBERNETES_SCHEMAS .. '/master-standalone-strict/service-v1.json',
          uri
        )
      end)

      it('warns about a document without apiVersion and kind', function()
        local bufnr = open(dir .. '/a.yaml', { 'kind: Pod' })
        fake_client({ buffers = { [bufnr] = true } })
        at(bufnr, 1)
        yaml_schema.insert_modeline(bufnr, { uri = 'kubernetes' })
        assert.are.same({ 'kind: Pod' }, lines_of(bufnr))
        assert.are.equal(vim.log.levels.WARN, notified[1].level)
      end)

      it('warns without yamlls', function()
        local bufnr = open(dir .. '/a.yaml', { 'apiVersion: v1', 'kind: Pod' })
        at(bufnr, 1)
        yaml_schema.insert_modeline(bufnr, { uri = 'kubernetes' })
        assert.are.equal(2, #lines_of(bufnr))
        assert.are.equal(vim.log.levels.WARN, notified[1].level)
      end)
    end)

    describe('for a local schema', function()
      local function modeline_for(file, schema)
        local bufnr = open(file, { 'a: 1' })
        fake_client({ buffers = { [bufnr] = true }, root_dir = dir .. '/proj' })
        at(bufnr, 1)
        yaml_schema.insert_modeline(bufnr, { uri = schema })
        return lines_of(bufnr)[1]:sub(#MODELINE + 1)
      end

      it('writes a path relative to the file inside the project', function()
        assert.are.equal(
          './schemas/s.json',
          modeline_for(dir .. '/proj/a.yaml', dir .. '/proj/schemas/s.json')
        )
        assert.are.equal(
          '../../schemas/s.json',
          modeline_for(dir .. '/proj/x/y/a.yaml', dir .. '/proj/schemas/s.json')
        )
      end)

      it(
        'turns a file URI into a path',
        function()
          assert.are.equal(
            './s.json',
            modeline_for(
              dir .. '/proj/a.yaml',
              vim.uri_from_fname(dir .. '/proj/s.json')
            )
          )
        end
      )

      it(
        'writes an absolute path for a schema outside the project',
        function()
          assert.are.equal(
            dir .. '/elsewhere/s.json',
            modeline_for(dir .. '/proj/a.yaml', dir .. '/elsewhere/s.json')
          )
        end
      )
    end)
  end)

  describe('use_file', function()
    it('warns about a file it cannot read', function()
      local bufnr = open(dir .. '/a.yaml', {})
      yaml_schema.use_file(bufnr, dir .. '/missing.json')
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
      assert.truthy(notified[1].msg:find('missing.json', 1, true))
    end)

    it('sets a readable file for the buffer', function()
      local schema = dir .. '/s.json'
      h.write(schema, { '{}' })
      local bufnr = open(dir .. '/a.yaml', {})
      local client = fake_client({ buffers = { [bufnr] = true } })
      local cwd = vim.fn.getcwd()
      vim.cmd.cd(dir)
      local ok, err = pcall(yaml_schema.use_file, 0, 's.json')
      vim.cmd.cd(cwd)
      assert(ok, err)
      assert.is_not_nil(client.settings.yaml.schemas[schema])
      assert.are.equal('s.json', vim.b[bufnr].yaml_schema_choice.name)
    end)

    it('writes a readable file as a modeline', function()
      local schema = dir .. '/s.json'
      h.write(schema, { '{}' })
      local bufnr = open(dir .. '/a.yaml', { 'a: 1' })
      local client =
        fake_client({ buffers = { [bufnr] = true }, root_dir = dir })
      yaml_schema.use_file(bufnr, schema, true)
      assert.are.equal(MODELINE .. './s.json', lines_of(bufnr)[1])
      assert.is_nil(client.settings.yaml)
    end)
  end)

  describe('browse', function()
    it('asks for a path from the project root', function()
      local bufnr = open(dir .. '/a.yaml', {})
      fake_client({ buffers = { [bufnr] = true }, root_dir = dir })
      local asked, used = nil, {}
      stub(vim.ui, 'input', function(opts, on_confirm)
        asked = opts
        on_confirm('')
        on_confirm(nil)
        on_confirm(dir .. '/s.json')
      end)
      stub(
        yaml_schema,
        'use_file',
        function(...) table.insert(used, { ... }) end
      )
      yaml_schema.browse(bufnr, true)
      assert.are.equal(dir .. '/', asked.default)
      assert.are.equal('file', asked.completion)
      assert.are.same({ { bufnr, dir .. '/s.json', true } }, used)
    end)
  end)

  describe('refresh_name', function()
    it('keeps the name of the schema the server uses', function()
      local bufnr = open(dir .. '/a.yaml', {})
      fake_client({
        buffers = { [bufnr] = true },
        responses = {
          ['yaml/get/jsonSchema'] = {
            { uri = 'https://e.x/s.json', name = 'T' },
          },
        },
      })
      yaml_schema.refresh_name(bufnr)
      assert.are.equal('T', vim.b[bufnr].yaml_schema_name)
    end)

    it('clears the name when the server uses none', function()
      local bufnr = open(dir .. '/a.yaml', {})
      vim.b[bufnr].yaml_schema_name = 'old'
      fake_client({
        buffers = { [bufnr] = true },
        responses = { ['yaml/get/jsonSchema'] = {} },
      })
      yaml_schema.refresh_name(bufnr)
      assert.is_nil(vim.b[bufnr].yaml_schema_name)
    end)

    it('keeps the name when the request fails', function()
      local bufnr = open(dir .. '/a.yaml', {})
      vim.b[bufnr].yaml_schema_name = 'old'
      fake_client({
        buffers = { [bufnr] = true },
        responses = { ['yaml/get/jsonSchema'] = function() return 'err' end },
      })
      yaml_schema.refresh_name(bufnr)
      assert.are.equal('old', vim.b[bufnr].yaml_schema_name)
    end)

    it('does nothing without yamlls', function()
      local bufnr = open(dir .. '/a.yaml', {})
      yaml_schema.refresh_name(bufnr)
      assert.is_nil(vim.b[bufnr].yaml_schema_name)
    end)
  end)

  describe('select', function()
    local project, selected

    --- Run `select` and wait for the picker it opens
    local function pick(bufnr, modeline)
      selected = nil
      yaml_schema.select(bufnr, modeline)
      assert(vim.wait(5000, function() return selected ~= nil end), 'no picker')
      return selected
    end

    local function by_uri(items, uri)
      for i, item in ipairs(items) do
        if item.uri == uri then return item, i end
      end
    end

    local function write_crds(paths, age)
      h.write(cache_file(), { vim.json.encode(paths) })
      if age then
        local t = os.time() - age
        vim.uv.fs_utime(cache_file(), t, t)
      end
    end

    before_each(function()
      project = dir .. '/proj'
      h.write(project .. '/schemas/one.json', { '{}' })
      h.write(project .. '/config.schema.yaml', { '{}' })
      h.write(project .. '/.schema/two.yml', { '{}' })
      h.write(project .. '/data.json', { '{}' })
      h.write(project .. '/schemas/readme.md', { '' })
      h.write(project .. '/node_modules/x/schema.json', { '{}' })
      h.write(dir .. '/shared/any.json', { '{}' })
      DyNeo.yaml_schema_dirs = { dir .. '/shared', dir .. '/does-not-exist' }
      write_crds({ 'cert-manager.io/certificate_v1.json', 'bad-path.json' })
      stub(
        vim.ui,
        'select',
        function(items, opts, on_choice)
          selected = { items = items, opts = opts, on_choice = on_choice }
        end
      )
    end)

    local function attached(bufnr, schemas)
      return fake_client({
        buffers = { [bufnr] = true },
        root_dir = project,
        responses = { ['yaml/get/all/jsonSchemas'] = schemas or {} },
      })
    end

    it('warns without yamlls', function()
      local bufnr = open(project .. '/a.yaml', {})
      yaml_schema.select(bufnr)
      assert.are.equal(vim.log.levels.WARN, notified[1].level)
    end)

    for _, finder in ipairs({ 'fd', 'the file system' }) do
      it('offers every kind of schema, found with ' .. finder, function()
        if finder ~= 'fd' then
          local executable = vim.fn.executable
          stub(vim.fn, 'executable', function(name)
            if name == 'fd' or name == 'fdfind' then return 0 end
            return executable(name)
          end)
        elseif
          vim.fn.executable('fd') == 0 and vim.fn.executable('fdfind') == 0
        then
          return pending('fd is not installed')
        end
        local bufnr = open(project .. '/a.yaml', {})
        local client = attached(bufnr, {
          {
            uri = vim.uri_from_fname(project .. '/schemas/one.json'),
            usedForCurrentFile = true,
          },
          { uri = 'https://e.x/known.json', name = 'Known' },
          -- Already in SchemaStore: listed once
          { uri = 'https://json.schemastore.org/compose.json', name = 'Dup' },
        })
        local items = pick(nil).items
        assert.are.equal('yaml/get/all/jsonSchemas', client.requests[1].method)
        assert.are.same(
          { vim.uri_from_bufnr(bufnr) },
          client.requests[1].params
        )

        local first = items[1]
        assert.are.equal(project .. '/schemas/one.json', first.uri)
        assert.are.equal('in use', first.source)
        assert.are.equal('schemas/one.json', first.name)
        assert.are.equal('file', first.preview)

        local locals = vim.tbl_map(
          function(i) return i.uri end,
          vim.tbl_filter(function(i) return i.source == 'local' end, items)
        )
        assert.are.same({
          project .. '/.schema/two.yml',
          project .. '/config.schema.yaml',
          dir .. '/shared/any.json',
          '',
        }, locals)
        local shared = by_uri(items, dir .. '/shared/any.json')
        assert.are.equal(
          vim.fn.fnamemodify(dir .. '/shared/any.json', ':~'),
          shared.name
        )
        assert.is_true(by_uri(items, '').browse)

        assert.are.equal('kubernetes', by_uri(items, 'kubernetes').source)
        assert.are.equal('cloud-init', by_uri(items, CLOUD_INIT).name)

        local workflow =
          by_uri(items, 'https://json.schemastore.org/github-workflow.json')
        assert.are.equal('schemastore', workflow.source)
        assert.are.same({ '**/.github/workflows/*.yml' }, workflow.file_match)
        local compose =
          by_uri(items, 'https://json.schemastore.org/compose.json')
        assert.are.equal('Docker Compose', compose.name)
        assert.are.same({ 'docker-compose.yml' }, compose.file_match)

        assert.are.equal(
          'yamlls',
          by_uri(items, 'https://e.x/known.json').source
        )

        local crd =
          by_uri(items, CRDS_CATALOG .. '/cert-manager.io/certificate_v1.json')
        assert.are.equal('certificate (cert-manager.io/v1)', crd.name)
        assert.are.equal('crds-catalog', crd.source)
        assert.is_nil(by_uri(items, CRDS_CATALOG .. '/bad-path.json'))

        local seen = {}
        for _, item in ipairs(items) do
          assert.is_nil(seen[item.uri], 'listed twice: ' .. item.uri)
          seen[item.uri] = true
        end
      end)
    end

    it('stops walking a large tree without fd, and says so', function()
      local executable = vim.fn.executable
      stub(vim.fn, 'executable', function(name)
        if name == 'fd' or name == 'fdfind' then return 0 end
        return executable(name)
      end)
      stub(yaml_schema, 'MAX_WALK', 2)
      local bufnr = open(project .. '/a.yaml', {})
      attached(bufnr)
      local locals = vim.tbl_filter(
        function(i) return i.source == 'local' and i.uri ~= '' end,
        pick(bufnr).items
      )
      assert.is_true(#locals < 3)
      assert.is_truthy(
        vim
          .iter(notified)
          :find(function(n) return n.msg:find('install fd', 1, true) ~= nil end)
      )
    end)

    it('formats items with their source', function()
      local bufnr = open(project .. '/a.yaml', {})
      attached(bufnr)
      local picked = pick(bufnr)
      assert.are.equal('YAML schema', picked.opts.prompt)
      assert.are.equal(
        'Kubernetes [kubernetes]',
        picked.opts.format_item(by_uri(picked.items, 'kubernetes'))
      )
    end)

    it('sets the schema picked', function()
      local bufnr = open(project .. '/a.yaml', {})
      local client = attached(bufnr)
      local picked = pick(bufnr)
      picked.on_choice(nil)
      assert.is_nil(client.settings.yaml)
      picked.on_choice(by_uri(picked.items, CLOUD_INIT))
      assert.are.equal(CLOUD_INIT, vim.b[bufnr].yaml_schema_choice.uri)
    end)

    it('offers to reset a schema chosen before', function()
      local bufnr = open(project .. '/a.yaml', {})
      attached(bufnr)
      yaml_schema.set(bufnr, { uri = CLOUD_INIT, name = 'cloud-init' })
      local picked = pick(bufnr)
      local reset = picked.items[1]
      assert.is_true(reset.reset)
      assert.are.equal('Currently: cloud-init', reset.description)
      picked.on_choice(reset)
      assert.is_nil(vim.b[bufnr].yaml_schema_choice)
    end)

    it('browses for a file', function()
      local bufnr = open(project .. '/a.yaml', {})
      attached(bufnr)
      local browsed
      stub(yaml_schema, 'browse', function(...) browsed = { ... } end)
      local picked = pick(bufnr, true)
      picked.on_choice(by_uri(picked.items, ''))
      assert.are.same({ bufnr, true }, browsed)
    end)

    it('writes the pick as a modeline, with no reset offered', function()
      local bufnr = open(project .. '/a.yaml', { 'a: 1' })
      attached(bufnr)
      yaml_schema.set(bufnr, { uri = CLOUD_INIT, name = 'cloud-init' })
      local picked = pick(bufnr, true)
      assert.are.equal('YAML schema modeline', picked.opts.prompt)
      assert.is_nil(picked.items[1].reset)
      picked.on_choice(
        by_uri(picked.items, 'https://e.x/known.json')
          or by_uri(picked.items, 'https://json.schemastore.org/compose.json')
      )
      assert.are.equal(
        MODELINE .. 'https://json.schemastore.org/compose.json',
        lines_of(bufnr)[1]
      )
    end)

    describe('the CRDs catalog', function()
      local system_calls, curl_output

      before_each(function()
        system_calls = {}
        local executable = vim.fn.executable
        stub(vim.fn, 'executable', function(name)
          if name == 'curl' then return 1 end
          if name == 'fd' or name == 'fdfind' then return 0 end
          return executable(name)
        end)
        stub(
          vim,
          'system',
          h.system_double(function(cmd)
            table.insert(system_calls, cmd)
            return curl_output
          end)
        )
      end)

      it('is read from a fresh cache without fetching', function()
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        pick(bufnr)
        assert.are.same({}, system_calls)
      end)

      it('is fetched again once the cache is a week old', function()
        write_crds({ 'old.io/thing_v1.json' }, 8 * 24 * 60 * 60)
        curl_output = {
          code = 0,
          stdout = vim.json.encode({
            tree = {
              { path = 'acme.io/widget_v1.json' },
              { path = 'acme.io' },
              { path = 'README.md' },
              { path = 'a/b/c.json' },
            },
          }),
        }
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        local items = pick(bufnr).items
        assert.are.equal('curl', system_calls[1][1])
        assert.is_not_nil(
          by_uri(items, CRDS_CATALOG .. '/acme.io/widget_v1.json')
        )
        assert.is_nil(by_uri(items, CRDS_CATALOG .. '/old.io/thing_v1.json'))
        assert.are.same(
          { 'acme.io/widget_v1.json' },
          vim.json.decode(table.concat(vim.fn.readfile(cache_file()), '\n'))
        )
        -- Kept for the rest of the session
        pick(bufnr)
        assert.are.equal(1, #system_calls)
      end)

      it('falls back on the stale cache when the fetch fails', function()
        write_crds({ 'old.io/thing_v1.json' }, 8 * 24 * 60 * 60)
        curl_output = { code = 22, stdout = '' }
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        local items = pick(bufnr).items
        assert.is_not_nil(
          by_uri(items, CRDS_CATALOG .. '/old.io/thing_v1.json')
        )
        assert.is_true(
          vim
            .iter(notified)
            :any(function(n) return n.level == vim.log.levels.WARN end)
        )
      end)

      it('is fetched when no cache exists, and copes without curl', function()
        vim.fn.delete(cache_file())
        stub(vim.fn, 'executable', function() return 0 end)
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        local items = pick(bufnr).items
        assert.are.same({}, system_calls)
        assert.is_nil(
          vim
            .iter(items)
            :find(function(i) return i.source == 'crds-catalog' end)
        )
      end)

      it('treats an unreadable cache as missing', function()
        h.write(cache_file(), { 'not json' })
        curl_output = { code = 0, stdout = '{"tree": []}' }
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        pick(bufnr)
        assert.are.equal(1, #system_calls)
      end)

      it('decides between a CRD and a built-in kind', function()
        -- A group in the catalog list is a CRD; one missing from it is not
        write_crds({ 'acme.io/widget_v1.json' })
        local bufnr = open(project .. '/a.yaml', {
          'apiVersion: cert-manager.io/v1',
          'kind: Certificate',
          '---',
          'apiVersion: acme.io/v1',
          'kind: Widget',
        })
        attached(bufnr)
        pick(bufnr)
        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        yaml_schema.insert_modeline(bufnr, { uri = 'kubernetes' })
        assert.are.equal(
          MODELINE
            .. KUBERNETES_SCHEMAS
            .. '/master-standalone-strict/certificate-cert-manager-v1.json',
          lines_of(bufnr)[1]
        )
        vim.api.nvim_win_set_cursor(0, { 6, 0 })
        yaml_schema.insert_modeline(bufnr, { uri = 'kubernetes' })
        assert.are.equal(
          MODELINE .. CRDS_CATALOG .. '/acme.io/widget_v1.json',
          lines_of(bufnr)[5]
        )
      end)
    end)

    describe('with Snacks', function()
      local spec

      before_each(function()
        package.loaded['snacks'] = {}
        _G.Snacks = { picker = { pick = function(s) spec = s end } }
        spec = nil
      end)

      local function snacks_pick(bufnr, modeline)
        yaml_schema.select(bufnr, modeline)
        assert(vim.wait(5000, function() return spec ~= nil end), 'no picker')
        return spec
      end

      local function fake_picker()
        local picker = { closed = false }
        function picker:close() self.closed = true end
        return picker
      end

      it('opens a picker with a preview of each schema', function()
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        local s = snacks_pick(bufnr)
        assert.are.equal('YAML schema', s.title)
        local workflow =
          by_uri(s.items, 'https://json.schemastore.org/github-workflow.json')
        assert.truthy(
          workflow.text:find('GitHub Workflow schemastore', 1, true)
        )
        assert.are.equal('markdown', workflow.preview.ft)
        assert.truthy(workflow.preview.text:find('# GitHub Workflow', 1, true))
        assert.truthy(workflow.preview.text:find('A workflow', 1, true))
        assert.truthy(
          workflow.preview.text:find('- `**/.github/workflows/*.yml`', 1, true)
        )
        assert.are.equal(
          'file',
          by_uri(s.items, project .. '/config.schema.yaml').preview
        )
      end)

      it('marks the schema in use and pads the names', function()
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        yaml_schema.set(bufnr, { uri = CLOUD_INIT, name = 'cloud-init' })
        local s = snacks_pick(bufnr)
        local active = s.format(by_uri(s.items, CLOUD_INIT))
        local other = s.format(by_uri(s.items, 'kubernetes'))
        assert.are.equal('● ', active[1][1])
        assert.are.equal('  ', other[1][1])
        assert.are.equal(
          vim.api.nvim_strwidth(active[2][1]),
          vim.api.nvim_strwidth(other[2][1])
        )
        assert.are.equal('cloud-init', active[4][1])
      end)

      it('applies the confirmed item', function()
        local bufnr = open(project .. '/a.yaml', {})
        attached(bufnr)
        local s = snacks_pick(bufnr)
        local picker = fake_picker()
        s.confirm(picker, by_uri(s.items, 'kubernetes'))
        assert.is_true(picker.closed)
        assert.are.equal('kubernetes', vim.b[bufnr].yaml_schema_choice.uri)
      end)

      it('writes an item as a modeline with its action', function()
        local bufnr = open(project .. '/a.yaml', { 'a: 1' })
        attached(bufnr)
        yaml_schema.set(bufnr, { uri = 'kubernetes', name = 'Kubernetes' })
        local s = snacks_pick(bufnr)
        assert.are.same({ 'n', 'i' }, s.win.input.keys['<M-m>'].mode)
        local action = s.actions.yaml_modeline

        action(fake_picker(), s.items[1]) -- the reset entry
        action(fake_picker(), nil)
        assert.are.same({ 'a: 1' }, lines_of(bufnr))

        local browsed
        stub(yaml_schema, 'browse', function(...) browsed = { ... } end)
        action(
          fake_picker(),
          vim.iter(s.items):find(function(i) return i.browse end)
        )
        assert.are.same({ bufnr, true }, browsed)

        action(fake_picker(), by_uri(s.items, CLOUD_INIT))
        assert.are.equal(MODELINE .. CLOUD_INIT, lines_of(bufnr)[1])
      end)
    end)
  end)

  describe('on_init', function()
    local client

    before_each(function()
      client = fake_client({ responses = { ['yaml/get/jsonSchema'] = {} } })
      stub(vim.lsp, 'get_client_by_id', function(id)
        for _, c in ipairs(clients) do
          if c.id == id then return c end
        end
      end)
    end)

    local function attach(bufnr, c)
      c.buffers[bufnr] = true
      vim.api.nvim_exec_autocmds('LspAttach', {
        buffer = bufnr,
        modeline = false,
        data = { client_id = c.id },
      })
    end

    it('hands the SchemaStore associations to the server', function()
      yaml_schema.on_init(client)
      local notes = sent(client, 'json/schemaAssociations')
      assert.are.same({ ['https://x/s.json'] = { '*.y' } }, notes[1].params)
    end)

    it('copes without SchemaStore', function()
      package.loaded['schemastore'] = nil
      stub(
        package.preload,
        'schemastore',
        function() error('not installed') end
      )
      yaml_schema.on_init(client)
      assert.are.same({}, client.sent)
    end)

    it('adds :DyYamlSchema to the buffers yamlls attaches to', function()
      yaml_schema.on_init(client)
      local bufnr = open(dir .. '/a.yaml', { 'apiVersion: v1', 'kind: Pod' })
      attach(bufnr, client)
      assert.is_not_nil(vim.api.nvim_buf_get_commands(bufnr, {}).DyYamlSchema)
      -- Detection ran, then the statusline name was asked for
      assert.are.equal('kubernetes', vim.b[bufnr].yaml_schema_choice.uri)
      assert.are.equal(2, #client.requests)
      assert.are.equal('yaml/get/jsonSchema', client.requests[2].method)
    end)

    it('asks for the name again on the diagnostics of yamlls only', function()
      yaml_schema.on_init(client)
      local bufnr = open(dir .. '/a.yaml', {})
      client.buffers[bufnr] = true
      local function changed(namespace)
        vim.api.nvim_exec_autocmds('DiagnosticChanged', {
          buffer = bufnr,
          modeline = false,
          data = { diagnostics = { { namespace = namespace, lnum = 0 } } },
        })
      end
      local yamlls = vim.api.nvim_create_namespace('dy_spec_yamlls')
      -- The real module wants a running client to load
      stub(vim.lsp, 'diagnostic', {
        get_namespace = function(id) return id == client.id and yamlls or -1 end,
      })
      local before = #client.requests
      changed(vim.api.nvim_create_namespace('dy_spec_yamllint'))
      assert.are.equal(before, #client.requests)
      changed(yamlls)
      assert.are.equal(before + 1, #client.requests)
      assert.are.equal(
        'yaml/get/jsonSchema',
        client.requests[#client.requests].method
      )
    end)

    it('leaves buffers of other servers alone', function()
      yaml_schema.on_init(client)
      local other = fake_client({ name = 'jsonls' })
      local bufnr = open(dir .. '/a.yaml', {})
      attach(bufnr, other)
      assert.is_nil(vim.api.nvim_buf_get_commands(bufnr, {}).DyYamlSchema)
    end)

    describe(':DyYamlSchema', function()
      local bufnr, calls

      before_each(function()
        yaml_schema.on_init(client)
        bufnr = open(dir .. '/a.yaml', {})
        attach(bufnr, client)
        calls = {}
        for _, name in ipairs({ 'reset', 'use_file', 'select' }) do
          stub(
            yaml_schema,
            name,
            function(...) table.insert(calls, { name, ... }) end
          )
        end
      end)

      it('opens the picker', function()
        vim.cmd('DyYamlSchema')
        vim.cmd('DyYamlSchema modeline')
        assert.are.same(
          { { 'select', bufnr, false }, { 'select', bufnr, true } },
          calls
        )
      end)

      it('resets', function()
        vim.cmd('DyYamlSchema reset')
        assert.are.same({ { 'reset', bufnr } }, calls)
      end)

      it('uses a file given by path', function()
        vim.cmd('DyYamlSchema some\\ dir/s.json')
        vim.cmd('DyYamlSchema modeline s.json')
        assert.are.same({
          { 'use_file', bufnr, 'some dir/s.json', false },
          { 'use_file', bufnr, 's.json', true },
        }, calls)
      end)

      it('completes the subcommands, then files', function()
        h.write(dir .. '/models.json', { '{}' })
        local cwd = vim.fn.getcwd()
        vim.cmd.cd(dir)
        local first = vim.fn.getcompletion('DyYamlSchema ', 'cmdline')
        local lead = vim.fn.getcompletion('DyYamlSchema mo', 'cmdline')
        local second =
          vim.fn.getcompletion('DyYamlSchema modeline mo', 'cmdline')
        vim.cmd.cd(cwd)
        assert.are.same({ 'modeline', 'reset' }, { first[1], first[2] })
        assert.is_true(vim.list_contains(first, 'models.json'))
        assert.are.same({ 'modeline', 'models.json' }, lead)
        assert.are.same({ 'models.json' }, second)
      end)
    end)

    it('refreshes the name when the diagnostics change', function()
      yaml_schema.on_init(client)
      local bufnr = open(dir .. '/a.yaml', {})
      client.buffers[bufnr] = true
      client.responses['yaml/get/jsonSchema'] = { { uri = CLOUD_INIT } }
      vim.diagnostic.set(vim.api.nvim_create_namespace('test.yaml'), bufnr, {})
      assert.are.equal('cloud-init', vim.b[bufnr].yaml_schema_name)
    end)

    it('detects again on write, and resets on wipeout', function()
      yaml_schema.on_init(client)
      local bufnr = open(dir .. '/a.yaml', { 'a: 1' })
      client.buffers[bufnr] = true
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { '#cloud-config' })
      vim.cmd('silent write')
      assert.are.equal(CLOUD_INIT, vim.b[bufnr].yaml_schema_choice.uri)
      assert.are.same(
        { dir .. '/a.yaml' },
        client.settings.yaml.schemas[CLOUD_INIT]
      )
      vim.cmd('bwipeout! ' .. bufnr)
      assert.is_nil(client.settings.yaml.schemas[CLOUD_INIT])
    end)

    it('replaces the autocmds of a previous start', function()
      yaml_schema.on_init(client)
      local count = #vim.api.nvim_get_autocmds({ group = 'util.yaml_schema' })
      yaml_schema.on_init(client)
      assert.are.equal(
        count,
        #vim.api.nvim_get_autocmds({ group = 'util.yaml_schema' })
      )
      assert.are.equal(4, count)
    end)
  end)
end)
