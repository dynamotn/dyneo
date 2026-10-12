local h = require('helpers')

describe('tools.workspace_diagnostics', function()
  local wd, dir, cleanup, restores, notified, listing, next_id

  local function stub(tbl, key, value)
    table.insert(restores, h.stub(tbl, key, value))
  end

  before_each(function()
    restores, notified = {}, {}
    next_id = (next_id or 1000) + 1
    dir, cleanup = h.tmpdir()
    -- What `git ls-files` lists, relative to the root; nil fails it
    listing = {}
    stub(require('util.system'), 'run', function(cmd, opts, on_done)
      assert.are.same({ 'git', 'ls-files' }, vim.list_slice(cmd, 1, 2))
      assert.are.equal(dir, opts.cwd)
      local result = { signal = 0, cut = false, timed_out = false }
      if listing then
        result.code, result.stdout, result.stderr =
          0, table.concat(listing, '\0'), ''
      else
        result.code, result.stdout, result.stderr =
          128, '', 'fatal: not a git repository\n'
      end
      on_done(result)
    end)
    stub(
      vim,
      'notify',
      function(msg, level) table.insert(notified, { msg = msg, level = level }) end
    )
    h.unload('tools.workspace_diagnostics')
    wd = require('tools.workspace_diagnostics')
  end)

  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  --- A language server double recording what it is notified of
  ---@param opts? { filetypes?: string[]|false, methods?: table<string, boolean>, name?: string }
  local function client(opts)
    opts = opts or {}
    local c = {
      id = next_id,
      name = opts.name or 'fake',
      sent = {},
      stopped = false,
      attached_buffers = {},
      root_dir = dir,
      config = {
        filetypes = opts.filetypes == nil and { 'lua' }
          or opts.filetypes
          or nil,
      },
      methods = opts.methods or { ['textDocument/didOpen'] = true },
    }
    c.notify = function(self, method, params)
      table.insert(self.sent, { method = method, params = params })
      return true
    end
    c.supports_method = function(self, method)
      return self.methods[method] or false
    end
    c.is_stopped = function(self) return self.stopped end
    stub(vim.lsp, 'get_client_by_id', function(id)
      if id == c.id then return c end
    end)
    return c
  end

  ---@param c table
  local function populate(c)
    wd.populate(c)
    vim.wait(2000, function() return #notified > 0 end)
  end

  ---@param c table
  ---@param method string
  ---@return string[] paths
  local function sent_paths(c, method)
    local paths = {}
    for _, n in ipairs(c.sent) do
      if n.method == method then
        table.insert(
          paths,
          vim.fs.basename(vim.uri_to_fname(n.params.textDocument.uri))
        )
      end
    end
    table.sort(paths)
    return paths
  end

  ---@param files table<string, string[]>
  local function files(files_)
    for name, lines in pairs(files_) do
      h.write(dir .. '/' .. name, lines)
      table.insert(listing, name)
    end
  end

  it('skips a server without filetypes', function()
    local c = client({ filetypes = false })
    wd.populate(c)
    assert.are.equal(
      'fake: skipped, it has no `filetypes` to pick the files by',
      notified[1].msg
    )
    assert.are.equal(vim.log.levels.WARN, notified[1].level)
  end)

  it('does nothing for a server not taking didOpen', function()
    local c = client({ methods = {} })
    wd.populate(c)
    vim.wait(100, function() return false end)
    assert.are.same({}, c.sent)
    assert.are.same({}, notified)
  end)

  it('opens every file of the server filetypes', function()
    files({
      ['a.lua'] = { 'return 1' },
      ['sub/b.lua'] = { 'x = 1' },
      ['c.py'] = { 'x = 1' },
    })
    local c = client()
    populate(c)
    assert.are.same({ 'a.lua', 'b.lua' }, sent_paths(c, 'textDocument/didOpen'))
    assert.are.equal('fake: 2 files sent', notified[1].msg)
    local doc = c.sent[1].params.textDocument
    assert.are.equal(0, doc.version)
    assert.are.equal('lua', doc.languageId)
    assert.is_truthy(doc.text == 'return 1\n' or doc.text == 'x = 1\n')
  end)

  it('tells a file without extension by its contents', function()
    files({ ['script'] = { '#!/usr/bin/env lua', 'print(1)' } })
    local c = client()
    populate(c)
    assert.are.same({ 'script' }, sent_paths(c, 'textDocument/didOpen'))
  end)

  it('never sends a sensitive file', function()
    files({ ['a.lua'] = { 'x' }, ['secrets/key.lua'] = { 'y' } })
    local c = client()
    populate(c)
    assert.are.same({ 'a.lua' }, sent_paths(c, 'textDocument/didOpen'))
  end)

  it('never sends a file holding a credential', function()
    files({
      ['a.lua'] = { 'x' },
      ['settings.lua'] = { 'local token = "ghp_0123456789abcdefghij"' },
    })
    local c = client()
    populate(c)
    assert.are.same({ 'a.lua' }, sent_paths(c, 'textDocument/didOpen'))
  end)

  it('skips binary and oversized files', function()
    files({ ['small.lua'] = { 'x' }, ['big.lua'] = { string.rep('x', 100) } })
    local file = assert(io.open(dir .. '/bin.lua', 'wb'))
    file:write('a\0b\n')
    file:close()
    table.insert(listing, 'bin.lua')
    wd.config.max_size = 50
    local c = client()
    populate(c)
    assert.are.same({ 'small.lua' }, sent_paths(c, 'textDocument/didOpen'))
  end)

  it('leaves alone files Neovim has open in the server', function()
    files({ ['a.lua'] = { 'x' }, ['b.lua'] = { 'y' } })
    local c = client()
    local bufnr = vim.fn.bufadd(dir .. '/a.lua')
    vim.fn.bufload(bufnr)
    c.attached_buffers[bufnr] = true
    populate(c)
    assert.are.same({ 'b.lua' }, sent_paths(c, 'textDocument/didOpen'))
  end)

  it('asks the server for the language id', function()
    files({ ['a.lua'] = { 'x' } })
    local c = client()
    c.config.get_language_id = true
    c.get_language_id = function(_, ft) return 'custom-' .. ft end
    populate(c)
    assert.are.equal('custom-lua', c.sent[1].params.textDocument.languageId)
  end)

  it('stops at max_files and warns', function()
    files({ ['a.lua'] = { 'x' }, ['b.lua'] = { 'y' }, ['c.lua'] = { 'z' } })
    wd.config.max_files = 2
    local c = client()
    populate(c)
    assert.are.equal(2, #sent_paths(c, 'textDocument/didOpen'))
    assert.are.equal(
      'fake: 2 files sent, stopped at `max_files`',
      notified[1].msg
    )
    assert.are.equal(vim.log.levels.WARN, notified[1].level)
  end)

  it('reports when the files cannot be listed', function()
    listing = nil
    local c = client()
    populate(c)
    assert.are.equal(
      'fake: cannot list files: fatal: not a git repository',
      notified[1].msg
    )
  end)

  it('closes files gone since the last run, and reopens the others', function()
    files({ ['a.lua'] = { 'x' }, ['b.lua'] = { 'y' } })
    local c = client()
    populate(c)
    c.sent, notified = {}, {}
    listing = { 'a.lua' }
    populate(c)
    assert.are.same(
      { 'a.lua', 'b.lua' },
      sent_paths(c, 'textDocument/didClose')
    )
    assert.are.same({ 'a.lua' }, sent_paths(c, 'textDocument/didOpen'))
    -- The reopened document is closed before it is opened again
    assert.are.equal('textDocument/didClose', c.sent[1].method)
  end)

  it('closes its document right before Neovim opens the same file', function()
    files({ ['a.lua'] = { 'x' } })
    local c = client()
    populate(c)
    c.sent = {}
    local uri = vim.uri_from_fname(dir .. '/a.lua')
    c:notify('textDocument/didOpen', { textDocument = { uri = uri } })
    assert.are.same(
      { 'textDocument/didClose', 'textDocument/didOpen' },
      vim.tbl_map(function(n) return n.method end, c.sent)
    )
    -- Once Neovim owns it, a new run leaves it alone
    c.sent, notified = {}, {}
    populate(c)
    assert.are.same({}, sent_paths(c, 'textDocument/didOpen'))
    -- And after Neovim closes it, the next run takes it back
    c:notify('textDocument/didClose', { textDocument = { uri = uri } })
    c.sent, notified = {}, {}
    populate(c)
    assert.are.same({ 'a.lua' }, sent_paths(c, 'textDocument/didOpen'))
  end)

  it('abandons a run overtaken by a stopped client', function()
    files({ ['a.lua'] = { 'x' } })
    local c = client()
    c.stopped = true
    wd.populate(c)
    vim.wait(200, function() return false end)
    assert.are.same({}, c.sent)
    assert.are.same({}, notified)
  end)

  describe('run', function()
    it('pulls, pushes or skips each server of the buffer', function()
      local pulled, populated = {}, {}
      local function fake(name, pull)
        return {
          id = name,
          name = name,
          supports_method = function(_, m)
            return m == 'workspace/diagnostic' and pull
          end,
        }
      end
      stub(vim.lsp, 'get_clients', function(filter)
        assert.are.same({ bufnr = 0 }, filter)
        return {
          fake('null-ls', true),
          fake('harper_ls', false),
          fake('copilot', false),
          fake('pull', true),
          fake('push', false),
        }
      end)
      stub(
        vim.lsp.buf,
        'workspace_diagnostics',
        function(o) table.insert(pulled, o.client_id) end
      )
      stub(wd, 'populate', function(c) table.insert(populated, c.name) end)
      wd.run()
      assert.are.same({ 'pull' }, pulled)
      assert.are.same({ 'push' }, populated)
    end)
  end)
end)
