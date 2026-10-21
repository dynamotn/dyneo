local h = require('helpers')

--- A client that supports `methods`, and records the commands it runs
---@param name string
---@param methods string[]
local function client(name, methods)
  return {
    name = name,
    id = #name,
    commands = {},
    server_capabilities = {},
    dynamic_capabilities = { get = function() return nil end },
    supports_method = function(_, method)
      return vim.list_contains(methods, method)
    end,
    exec_cmd = function(self, params, ctx)
      table.insert(self.commands, { params = params, ctx = ctx })
    end,
  }
end

describe('util.lsp', function()
  local lsp, clients, filters, restores

  before_each(function()
    clients, filters = {}, {}
    restores = {
      h.stub(vim.lsp, 'get_clients', function(filter)
        table.insert(filters, filter)
        return vim.tbl_filter(
          function(c) return not filter.name or c.name == filter.name end,
          clients
        )
      end),
      h.stub(
        require('util.plugin'),
        'opts',
        function() return { format = { timeout_ms = 500 } } end
      ),
    }
    h.unload('util.lsp')
    lsp = require('util.lsp')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  describe('formatter', function()
    it('is the primary, lowest priority formatter', function()
      local f = lsp.formatter()
      assert.are.equal('LSP', f.name)
      assert.is_true(f.primary)
      assert.are.equal(1, f.priority)
    end)

    it('names the clients of the buffer that can format', function()
      clients = {
        client('lua_ls', { 'textDocument/formatting' }),
        client('harper_ls', { 'textDocument/hover' }),
        client('taplo', { 'textDocument/rangeFormatting' }),
      }
      assert.are.same({ 'lua_ls', 'taplo' }, lsp.formatter().sources(3))
      assert.are.equal(3, filters[1].bufnr)
    end)

    it('takes a client name as its filter', function()
      clients = {
        client('vtsls', { 'textDocument/formatting' }),
        client('eslint', { 'textDocument/formatting' }),
      }
      assert.are.same(
        { 'eslint' },
        lsp.formatter({ filter = 'eslint' }).sources(0)
      )
    end)
  end)

  describe('format', function()
    it('goes through conform, with the formatter list left to it', function()
      local seen
      table.insert(
        restores,
        h.stub(package.loaded, 'conform', {
          format = function(opts) seen = opts end,
        })
      )
      lsp.format({ bufnr = 4, formatters = { 'x' } })
      assert.are.equal(4, seen.bufnr)
      assert.are.equal(500, seen.timeout_ms)
      assert.is_nil(seen.formatters)
    end)
  end)

  it('formats nothing under a held directory', function()
    local dir, cleanup = h.tmpdir()
    h.unload('util.untrusted')
    local untrusted = require('util.untrusted')
    local seen = 0
    table.insert(
      restores,
      h.stub(package.loaded, 'conform', {
        format = function() seen = seen + 1 end,
      })
    )
    local bufnr = h.buffer({ name = dir .. '/a.lua' })
    untrusted.hold(dir)
    lsp.format({ bufnr = bufnr })
    vim.api.nvim_set_current_buf(bufnr)
    lsp.format()
    assert.are.equal(0, seen)
    untrusted.release(dir)
    lsp.format({ bufnr = bufnr })
    assert.are.equal(1, seen)
    cleanup()
  end)

  it('formats through the LSP itself without conform', function()
    local seen
    table.insert(restores, h.stub(package.loaded, 'conform', nil))
    table.insert(
      restores,
      h.stub(package.preload, 'conform', function() error('not installed') end)
    )
    table.insert(
      restores,
      h.stub(vim.lsp.buf, 'format', function(opts) seen = opts end)
    )
    lsp.format({ bufnr = 4 })
    assert.are.equal(4, seen.bufnr)
    assert.are.equal(500, seen.timeout_ms)
  end)

  it('applies a code action of the kind asked for', function()
    local seen
    table.insert(
      restores,
      h.stub(vim.lsp.buf, 'code_action', function(opts) seen = opts end)
    )
    lsp.action['source.organizeImports']()
    assert.is_true(seen.apply)
    assert.are.same({ 'source.organizeImports' }, seen.context.only)
  end)

  describe('execute', function()
    it('runs the command on the first matching client', function()
      local vtsls = client('vtsls', {})
      clients = { vtsls }
      lsp.execute({
        command = 'typescript.restart',
        arguments = { 1 },
        filter = 'vtsls',
        title = 'Restart',
      })
      local params = vtsls.commands[1].params
      assert.are.equal('typescript.restart', params.command)
      assert.are.same({ 1 }, params.arguments)
    end)

    it('warns rather than fails with no client to run it', function()
      clients = {}
      local warned
      table.insert(
        restores,
        h.stub(vim, 'notify', function(msg) warned = msg end)
      )
      assert.has_no.errors(function() lsp.execute({ command = 'x.y' }) end)
      assert.is_truthy(warned:find('x.y', 1, true))
    end)

    it('shows the result in trouble with `open`', function()
      local seen
      table.insert(
        restores,
        h.stub(package.loaded, 'trouble', {
          open = function(opts) seen = opts end,
        })
      )
      lsp.execute({ command = 'x.refs', open = true })
      assert.are.equal('lsp_command', seen.mode)
      assert.are.equal('x.refs', seen.params.command)
    end)
  end)

  it('lists the code action kinds of the clients, once each', function()
    local a = client('a', {})
    a.server_capabilities.codeActionProvider =
      { codeActionKinds = { 'quickfix', 'source.organizeImports' } }
    local b = client('b', {})
    b.dynamic_capabilities.get = function()
      return { { registerOptions = { codeActionKinds = { 'quickfix' } } } }
    end
    clients = { a, b }
    assert.are.same(
      { 'quickfix', 'source.organizeImports' },
      lsp.code_actions()
    )
  end)

  describe('keymaps.set', function()
    local set
    before_each(function()
      set = {}
      table.insert(
        restores,
        h.stub(_G, 'Snacks', {
          keymap = {
            set = function(mode, lhs, _, opts)
              table.insert(set, { mode = mode, lhs = lhs, opts = opts })
            end,
          },
        })
      )
    end)

    it('limits a key to the clients supporting its method', function()
      lsp.keymaps.set({ name = 'lua_ls' }, {
        { 'gd', function() end, desc = 'Definition', has = 'definition' },
      })
      assert.are.equal(1, #set)
      assert.are.equal('gd', set[1].lhs)
      assert.are.same(
        { name = 'lua_ls', method = 'textDocument/definition' },
        set[1].opts.lsp
      )
    end)

    it('sets a key once per method it accepts', function()
      lsp.keymaps.set({}, {
        {
          '<leader>cR',
          function() end,
          has = { 'workspace/didRenameFiles', 'workspace/willRenameFiles' },
        },
      })
      assert.are.same(
        { 'workspace/didRenameFiles', 'workspace/willRenameFiles' },
        vim.tbl_map(function(s) return s.opts.lsp.method end, set)
      )
    end)

    it('sets a key without `has` for every client of the filter', function()
      lsp.keymaps.set({ name = 'x' }, { { 'K', function() end } })
      assert.are.same({ name = 'x' }, set[1].opts.lsp)
    end)
  end)

  describe('with vim.lsp.codelens stubbed', function()
    local calls, enabled, restore_codelens

    --- Stand in for `vim.lsp.codelens`, with `enable` only when `native`
    ---@param native boolean
    local function codelens(native)
      local fake = {
        refresh = function(opts) table.insert(calls, { 'refresh', opts }) end,
      }
      if native then
        fake.enable = function(on, filter)
          enabled[filter.bufnr] = on
          table.insert(calls, { 'enable', on, filter })
        end
        fake.is_enabled = function(filter) return enabled[filter.bufnr] == true end
      end
      restore_codelens = h.stub(vim.lsp, 'codelens', fake)
    end

    before_each(function()
      calls, enabled = {}, {}
    end)
    after_each(function() restore_codelens() end)

    describe('codelens', function()
      it('enables the lenses of the buffer where Neovim can', function()
        codelens(true)
        lsp.codelens.enable(7)
        assert.same({ { 'enable', true, { bufnr = 7 } } }, calls)
      end)

      it('refreshes that buffer alone on the events otherwise', function()
        codelens(false)
        local buf = vim.api.nvim_create_buf(true, false)
        lsp.codelens.enable(buf)
        vim.api.nvim_exec_autocmds('InsertLeave', { buffer = buf })
        assert.same({
          { 'refresh', { bufnr = buf } },
          { 'refresh', { bufnr = buf } },
        }, calls)
        vim.api.nvim_buf_delete(buf, { force = true })
      end)

      it('toggles the lenses of the current buffer', function()
        codelens(true)
        local buf = vim.api.nvim_get_current_buf()
        lsp.codelens.toggle()
        assert.is_true(enabled[buf])
        lsp.codelens.toggle()
        assert.is_false(enabled[buf])
      end)
    end)
  end)
end)
