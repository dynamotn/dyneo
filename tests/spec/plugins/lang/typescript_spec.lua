local h = require('helpers')

describe('plugins.lang.typescript', function()
  local restores, hooks, specs

  --- The spec of `name` among those `plugins.lang.typescript` returns; the
  --- `nth` of that name when several carry it
  ---@param name string
  ---@param nth? integer
  ---@return table
  local function spec(name, nth)
    local seen = 0
    for _, s in ipairs(specs) do
      if s[1] == name then
        seen = seen + 1
        if seen == (nth or 1) then return s end
      end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    hooks = {}
    restores = {
      h.stub(_G, 'Snacks', {
        util = {
          lsp = {
            on = function(filter, fn) table.insert(hooks, { filter, fn }) end,
          },
        },
      }),
    }
    specs = dofile(h.root .. '/lua/plugins/lang/typescript.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('hooks vtsls once, however many languages name it', function()
    local setup = spec('neovim/nvim-lspconfig').opts.setup.vtsls
    local opts = { settings = { typescript = { suggest = { x = true } } } }
    for _ = 1, 4 do
      assert.is_nil((setup('vtsls', opts)))
    end
    assert.are.equal(1, #hooks)
    assert.same({ suggest = { x = true } }, opts.settings.javascript)
  end)

  it('has nothing to add when no language of the family is on', function()
    DyNeo.enabled_languages = { 'lua', 'python' }
    assert.same({}, dofile(h.root .. '/lua/plugins/lang/typescript.lua'))
    DyNeo.enabled_languages = { 'astro' }
    assert.is_true(#dofile(h.root .. '/lua/plugins/lang/typescript.lua') > 0)
  end)

  it('serves every TypeScript filetype with vtsls', function()
    local opts = { servers = { vtsls = { filetypes = { 'javascript' } } } }
    spec('neovim/nvim-lspconfig', 2).opts(nil, opts)
    assert.same({ 'javascript', 'typescript' }, opts.servers.vtsls.filetypes)
  end)

  describe('keys', function()
    local executed, actions

    before_each(function()
      executed, actions = {}, {}
      local lsp = require('util.lsp')
      table.insert(
        restores,
        h.stub(lsp, 'execute', function(opts) table.insert(executed, opts) end)
      )
      table.insert(
        restores,
        h.stub(
          vim.lsp.buf,
          'code_action',
          function(opts) table.insert(actions, opts.context.only[1]) end
        )
      )
    end)

    it(
      'asks vtsls for the source definition and the file references',
      function()
        local keys = {}
        for _, key in
          ipairs(spec('neovim/nvim-lspconfig').opts.servers.vtsls.keys)
        do
          keys[key[1]] = key[2]
        end
        local bufnr =
          h.buffer({ name = '/tmp/dy/a.ts', lines = { 'const a = 1' } })
        vim.api.nvim_set_current_buf(bufnr)
        vim.api.nvim_win_set_cursor(0, { 1, 6 })
        keys['gD']()
        assert.are.equal('typescript.goToSourceDefinition', executed[1].command)
        assert.is_true(executed[1].open)
        assert.are.equal(vim.uri_from_bufnr(bufnr), executed[1].arguments[1])
        assert.same({ line = 0, character = 6 }, executed[1].arguments[2])
        keys['gR']()
        assert.are.equal(
          'typescript.findAllFileReferences',
          executed[2].command
        )
        assert.same({ vim.uri_from_bufnr(bufnr) }, executed[2].arguments)
        keys['<leader>cV']()
        assert.are.equal(
          'typescript.selectTypeScriptVersion',
          executed[3].command
        )
        assert.is_nil(executed[3].open)

        keys['<leader>co']()
        keys['<leader>cM']()
        keys['<leader>cu']()
        keys['<leader>cD']()
        assert.same({
          'source.organizeImports',
          'source.addMissingImports.ts',
          'source.removeUnused.ts',
          'source.fixAll.ts',
        }, actions)
      end
    )
  end)

  describe('move to file', function()
    local client, requests, selected, typed, command

    before_each(function()
      requests = {}
      client = {
        commands = {},
        request = function(_, method, params, handler)
          table.insert(requests, { method = method, params = params })
          if params.arguments[1] == 'getMoveToRefactoringFileSuggestions' then
            handler(nil, { body = { files = { '/p/a.ts', '/p/b.ts' } } })
          end
        end,
      }
      spec('neovim/nvim-lspconfig').opts.setup.vtsls('vtsls', {
        settings = { typescript = {} },
      })
      assert.are.equal('vtsls', hooks[1][1].name)
      hooks[1][2](nil, client)
      table.insert(
        restores,
        h.stub(vim.ui, 'select', function(items, opts, on_choice)
          assert.are.equal('Enter new path...', items[1])
          assert.are.equal('a.ts', opts.format_item('/p/a.ts'):match('[^/]+$'))
          on_choice(selected)
        end)
      )
      table.insert(
        restores,
        h.stub(vim.ui, 'input', function(opts, on_confirm)
          assert.are.equal('/p/', opts.default)
          on_confirm(typed)
        end)
      )
      command = {
        command = '_typescript.moveToFileRefactoring',
        arguments = {
          'Move to file',
          'file:///p/x.ts',
          {
            start = { line = 2, character = 4 },
            ['end'] = { line = 5, character = 0 },
          },
        },
      }
    end)

    it('moves the code to the file picked', function()
      selected = '/p/b.ts'
      client.commands[command.command](command)
      assert.are.equal(2, #requests)
      local suggestions = requests[1].params.arguments[2]
      assert.same({
        file = '/p/x.ts',
        startLine = 3,
        startOffset = 5,
        endLine = 6,
        endOffset = 1,
      }, suggestions)
      assert.are.equal('workspace/executeCommand', requests[2].method)
      assert.same({
        command = command.command,
        arguments = {
          'Move to file',
          'file:///p/x.ts',
          command.arguments[3],
          '/p/b.ts',
        },
      }, requests[2].params)
    end)

    it('asks for a new path when none of the suggestions fits', function()
      selected = 'Enter new path...'
      typed = '/p/new.ts'
      client.commands[command.command](command)
      assert.are.equal('/p/new.ts', requests[2].params.arguments[4])

      -- The prompt left empty, or the picker dismissed, moves nothing
      typed = nil
      client.commands[command.command](command)
      selected = nil
      client.commands[command.command](command)
      assert.are.equal(4, #requests)
    end)
  end)

  describe('debugging', function()
    local dap, dap_opts

    before_each(function()
      dap = { adapters = {}, configurations = {} }
      table.insert(restores, h.stub(package.loaded, 'dap', dap))
      table.insert(
        restores,
        h.stub(package.loaded, 'dap.utils', { pick_process = 'pick' })
      )
      table.insert(
        restores,
        h.stub(
          vim.fn,
          'executable',
          function(name) return name == 'tsx' and 1 or 0 end
        )
      )
      dap_opts = spec('mfussenegger/nvim-dap').opts
    end)

    it('registers js-debug under both the pwa and the VSCode names', function()
      dap_opts()
      assert.are.equal('server', dap.adapters['pwa-node'].type)
      assert.are.equal(
        'js-debug-adapter',
        dap.adapters['pwa-chrome'].executable.command
      )
      local given
      local config = { type = 'node' }
      dap.adapters.node(function(adapter) given = adapter end, config)
      assert.are.equal(dap.adapters['pwa-node'], given)
      assert.are.equal('pwa-node', config.type)

      -- A pwa adapter that is a function is called with the callback
      dap.adapters['pwa-msedge'] = function(cb, c) cb({ via = c.type }) end
      dap.adapters.msedge(
        function(adapter) given = adapter end,
        { type = 'msedge' }
      )
      assert.same({ via = 'pwa-msedge' }, given)

      -- Run again, nothing registered is replaced
      local pwa_node, node = dap.adapters['pwa-node'], dap.adapters.node
      dap_opts()
      assert.are.equal(pwa_node, dap.adapters['pwa-node'])
      assert.are.equal(node, dap.adapters.node)
    end)

    it('launches TypeScript through tsx, ahead of what was there', function()
      dap.configurations.typescript = { { name = 'Firefox' } }
      dap_opts()
      local ts = dap.configurations.typescript
      assert.are.equal('Launch file', ts[1].name)
      assert.are.equal('tsx', ts[1].runtimeExecutable)
      assert.are.equal('pick', ts[2].processId)
      assert.are.equal('Firefox', ts[3].name)
      assert.are.equal('Launch Chrome', ts[4].name)
      assert.is_nil(dap.configurations.javascript[1].runtimeExecutable)
      -- Components only run in the browser
      assert.are.equal(1, #dap.configurations.vue)
      assert.are.equal('pwa-chrome', dap.configurations.vue[1].type)

      table.insert(
        restores,
        h.stub(vim.fn, 'input', function(_, default) return default end)
      )
      vim.api.nvim_set_current_buf(h.buffer({ filetype = 'vue' }))
      assert.are.equal('http://localhost:5173', dap.configurations.vue[1].url())
    end)
  end)

  it('runs jest from the root of the project', function()
    table.insert(
      restores,
      h.stub(require('util.root'), 'get', function() return '/root/app' end)
    )
    local jest = spec('nvim-neotest/neotest').opts.adapters['neotest-jest']
    assert.are.equal('/root/app', jest.cwd())
    assert.is_true(jest.env.CI)
  end)
end)
