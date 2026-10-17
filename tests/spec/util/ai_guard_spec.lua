local h = require('helpers')

describe('util.ai_guard', function()
  local ai_guard, dir, cleanup, notes, restore_notify, secret, plain

  local plugin_modules = {
    'avante.api',
    'avante.file_selector',
    'avante.llm_tools.helpers',
    'avante.utils',
    'avante.libs.acp_client',
    'sidekick.cli',
    'sidekick.status',
    'sidekick.config',
    'claudecode.selection',
    'claudecode',
    'pantran.command',
    'lazy.core.config',
  }

  before_each(function()
    dir, cleanup = h.tmpdir()
    secret, plain = dir .. '/.env', dir .. '/main.lua'
    notes = {}
    restore_notify = h.stub(
      vim,
      'notify',
      function(msg, level) table.insert(notes, { msg = msg, level = level }) end
    )
    h.unload(
      'util.ai_guard',
      'util.ai_audit',
      'util.ai_policy',
      unpack(plugin_modules)
    )
    ai_guard = require('util.ai_guard')
  end)
  after_each(function()
    restore_notify()
    h.unload(unpack(plugin_modules))
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  --- Make `path` the current buffer
  local function edit(path)
    vim.api.nvim_set_current_buf(h.buffer({ name = path }))
  end

  --- A function recording that it ran, returning `ret`
  local function spy(ret)
    local calls = {}
    return setmetatable({ calls = calls }, {
      __call = function(_, ...)
        table.insert(calls, { ... })
        return ret
      end,
    }),
      calls
  end

  --- A plain function wrapping `spy` (the guard checks `type == 'function'`)
  local function fn(ret)
    local s, calls = spy(ret)
    return function(...) return s(...) end, calls
  end

  local function refused()
    for _, note in ipairs(notes) do
      if note.msg:find('refused') then return true end
    end
    return false
  end

  --- What `util.ai_audit` logged, as `integration action path (detail)`
  ---@return string[]
  local function audited()
    return vim.tbl_map(
      function(entry)
        return ('%s %s %s (%s)'):format(
          entry.integration,
          entry.action,
          entry.what,
          entry.detail or ''
        )
      end,
      require('util.ai_audit').entries
    )
  end

  describe('guard_avante', function()
    local api, selector, helpers, utils, acp, calls

    before_each(function()
      calls = {}
      api, calls.ask = {}, nil
      api.ask, calls.ask = fn('asked')
      api.edit, calls.edit = fn('edited')
      selector = {}
      selector.add_selected_file, calls.add = fn('added')
      helpers = {}
      helpers.has_permission_to_access, calls.perm = fn(true)
      utils = {}
      utils.read_file_from_buf_or_disk, calls.read = fn('content')
      package.loaded['avante.api'] = api
      package.loaded['avante.file_selector'] = selector
      package.loaded['avante.llm_tools.helpers'] = helpers
      package.loaded['avante.utils'] = utils
      acp = { errors = {} }
      acp._handle_write_text_file, calls.write = fn('written')
      function acp:_send_error(id, message)
        table.insert(self.errors, { id, message })
      end
      package.loaded['avante.libs.acp_client'] = acp
      ai_guard.guard_avante()
    end)

    it('writes no sensitive file an ACP agent asks for', function()
      acp:_handle_write_text_file(1, { sessionId = 's', path = secret })
      assert.same({ { 1, 'the file is sensitive' } }, acp.errors)
      assert.equals(0, #calls.write)
      assert.equals(
        'written',
        acp:_handle_write_text_file(2, { sessionId = 's', path = plain })
      )
      assert.equals(1, #calls.write)
    end)

    it('refuses ask and edit from a sensitive buffer', function()
      edit(secret)
      assert.is_nil(api.ask())
      assert.is_nil(api.edit())
      assert.equals(0, #calls.ask + #calls.edit)
      assert.is_true(refused())
    end)

    it('passes ask and edit through elsewhere', function()
      edit(plain)
      assert.equals('asked', api.ask('q'))
      assert.equals('edited', api.edit())
      assert.same({ 'q' }, calls.ask[1])
    end)

    it('logs what went out and what was refused', function()
      edit(plain)
      api.ask('q')
      selector.add_selected_file(selector, secret)
      helpers.has_permission_to_access(plain)
      assert.same({
        'Avante sent ' .. plain .. ' (ask)',
        'Avante refused ' .. secret .. ' ()',
        'Avante sent ' .. plain .. ' (tool)',
      }, audited())
    end)

    it('refuses to add a sensitive file to the chat', function()
      assert.is_nil(selector.add_selected_file(selector, secret))
      assert.equals(0, #calls.add)
      assert.equals('added', selector.add_selected_file(selector, plain))
      assert.equals('added', selector.add_selected_file(selector, ''))
      assert.equals(2, #calls.add)
    end)

    it('denies the tools a sensitive path', function()
      assert.is_false(helpers.has_permission_to_access(secret))
      assert.is_true(helpers.has_permission_to_access(plain))
      assert.equals(1, #calls.perm)
    end)

    it('does not read a sensitive file', function()
      local content, err = utils.read_file_from_buf_or_disk(secret)
      assert.is_nil(content)
      assert.equals('the file is sensitive', err)
      assert.equals('content', utils.read_file_from_buf_or_disk(plain))
    end)
  end)

  it('warns and leaves a plugin alone when a function is missing', function()
    package.loaded['avante.api'] = { ask = 'not a function' }
    ai_guard.guard_avante()
    assert.equals('not a function', package.loaded['avante.api'].ask)
    local missing = {}
    for _, note in ipairs(notes) do
      if note.msg:find('left unguarded') then
        table.insert(missing, note.msg)
      end
    end
    -- ask, edit, add_selected_file, the permission, the file reader and
    -- the ACP file writer
    assert.equals(6, #missing)
    assert.equals(vim.log.levels.WARN, notes[1].level)
  end)

  describe('guard_sidekick', function()
    local cli, status, send_calls, get_result, config

    before_each(function()
      get_result = nil
      cli = {}
      cli.send, send_calls = fn('sent')
      status = { get = function() return get_result end }
      config = {
        copilot = { status = { enabled = true } },
        get_clients = function() return { {} } end,
      }
      package.loaded['sidekick.cli'] = cli
      package.loaded['sidekick.status'] = status
      package.loaded['sidekick.config'] = config
      ai_guard.guard_sidekick()
    end)

    it('refuses to send from a sensitive buffer', function()
      edit(secret)
      assert.is_nil(cli.send({ msg = '{this}' }))
      assert.equals(0, #send_calls)
      assert.is_true(refused())
      edit(plain)
      assert.equals('sent', cli.send())
    end)

    it('logs the prompt a buffer was sent with', function()
      edit(plain)
      cli.send({ prompt = 'review' })
      assert.same(
        { 'sidekick sent ' .. plain .. ' (prompt review)' },
        audited()
      )
    end)

    it('reports a sensitive buffer as inactive', function()
      local buf = h.buffer({ name = secret })
      assert.same(
        { busy = false, kind = 'Inactive', message = 'sensitive file' },
        status.get(buf)
      )
    end)

    it(
      'says nothing for a sensitive buffer when Copilot is not running',
      function()
        local buf = h.buffer({ name = secret })
        config.get_clients = function() return {} end
        assert.is_nil(status.get(buf))
        config.get_clients = function() return { {} } end
        config.copilot.status.enabled = false
        assert.is_nil(status.get(buf))
      end
    )

    it('keeps the real status', function()
      get_result = { kind = 'Normal' }
      assert.equals(get_result, status.get(h.buffer({ name = secret })))
      get_result = nil
      assert.is_nil(status.get(h.buffer({ name = plain })))
    end)
  end)

  describe('in a project keeping AI local', function()
    local kept

    before_each(function()
      kept = dir .. '/kept/main.lua'
      h.write(dir .. '/kept/.nvim/ai.json', { '{ "local_only": true }' })
      _G.DyNeo.ai = { local_providers = { 'ollama' } }
    end)
    after_each(function()
      _G.DyNeo.ai = nil
      package.loaded['avante.config'] = nil
    end)

    it('sends nothing to a CLI of sidekick', function()
      local cli = {}
      local calls
      cli.send, calls = fn('sent')
      package.loaded['sidekick.cli'] = cli
      ai_guard.guard_sidekick()
      edit(kept)
      assert.is_nil(cli.send({ msg = '{this}' }))
      assert.equals(0, #calls)
      assert.is_true(refused())
      edit(plain)
      assert.equals('sent', cli.send())
    end)

    it('lets Avante ask only a local provider', function()
      local api = {}
      local calls
      api.ask, calls = fn('asked')
      api.edit = fn('edited')
      package.loaded['avante.api'] = api
      package.loaded['avante.config'] = { provider = 'claude-code' }
      ai_guard.guard_avante()
      edit(kept)
      assert.is_nil(api.ask())
      assert.equals(0, #calls)
      package.loaded['avante.config'].provider = 'ollama'
      assert.equals('asked', api.ask())
    end)

    it('mentions none of its files to Claude Code', function()
      local claudecode = {}
      local calls
      claudecode.send_at_mention, calls = fn(true)
      package.loaded['claudecode'] = claudecode
      package.loaded['claudecode.selection'] = {
        update_selection = fn(),
        send_selection_update = fn(),
        get_latest_selection = fn({ filePath = kept }),
      }
      ai_guard.guard_claudecode()
      assert.is_false((claudecode.send_at_mention(kept, 1, 2)))
      assert.equals(0, #calls)
      assert.is_nil(
        package.loaded['claudecode.selection'].get_latest_selection()
      )
    end)
  end)

  describe('guard_pantran', function()
    it('refuses to translate out of a sensitive buffer', function()
      local command = {}
      local calls
      command._translate, calls = fn('translated')
      package.loaded['pantran.command'] = command
      ai_guard.guard_pantran()
      edit(secret)
      assert.is_nil(command._translate('text'))
      assert.equals(0, #calls)
      assert.is_true(refused())
      edit(plain)
      assert.equals('translated', command._translate('text'))
    end)
  end)

  describe('guard_claudecode', function()
    local selection, claudecode, update_calls, mention_calls, send_calls
    local latest

    before_each(function()
      selection, claudecode = {}, {}
      selection.update_selection, update_calls = fn()
      selection.send_selection_update, send_calls = fn()
      selection.get_latest_selection = function() return latest end
      claudecode.send_at_mention, mention_calls = fn(true)
      package.loaded['claudecode.selection'] = selection
      package.loaded['claudecode'] = claudecode
      ai_guard.guard_claudecode()
    end)

    it('skips the selection update in a sensitive buffer', function()
      edit(secret)
      selection.update_selection()
      assert.equals(0, #update_calls)
      edit(plain)
      selection.update_selection()
      assert.equals(1, #update_calls)
    end)

    it('drops the selection flushed on leaving visual mode', function()
      selection.send_selection_update({ filePath = secret, text = 'TOKEN=x' })
      assert.equals(0, #send_calls)
      selection.send_selection_update({ filePath = plain, text = 'x' })
      assert.equals(1, #send_calls)
    end)

    it('checks the content of the buffer a selection came from', function()
      h.buffer({
        name = plain,
        lines = { 'token = "ghp_0123456789abcdefghij"' },
      })
      selection.send_selection_update({ filePath = plain, text = 'token' })
      assert.equals(0, #send_calls)
    end)

    it('hides a sensitive selection from the selection tools', function()
      latest = { filePath = secret, text = 'TOKEN=x' }
      assert.is_nil(selection.get_latest_selection())
      latest = { filePath = plain, text = 'x' }
      assert.same(latest, selection.get_latest_selection())
    end)

    it('refuses to mention a sensitive file', function()
      local ok, err = claudecode.send_at_mention(secret)
      assert.is_false(ok)
      assert.equals('the file is sensitive', err)
      assert.is_true(refused())
      assert.is_true(claudecode.send_at_mention(plain, 1, 2))
      assert.same({ plain, 1, 2 }, mention_calls[1])
      assert.is_true(claudecode.send_at_mention(nil))
    end)

    it('logs a mention and a selection once a minute', function()
      edit(plain)
      claudecode.send_at_mention(plain, 1, 2)
      selection.update_selection()
      selection.update_selection()
      assert.same({
        'Claude Code sent ' .. plain .. ' (lines 1-2)',
        'Claude Code sent ' .. plain .. ' (selection)',
      }, audited())
    end)

    it('does not log a buffer that is no file', function()
      local buf = h.buffer({ name = plain })
      vim.bo[buf].buftype = 'nofile'
      vim.api.nvim_set_current_buf(buf)
      selection.update_selection()
      assert.same({}, audited())
    end)
  end)

  describe('watch_copilot', function()
    local restore_clients, restore_detach, detached

    before_each(function()
      detached = {}
      restore_clients = h.stub(vim.lsp, 'get_clients', function(filter)
        assert.equals('copilot', filter.name)
        return { { id = 42 } }
      end)
      restore_detach = h.stub(
        vim.lsp,
        'buf_detach_client',
        function(buf, id) table.insert(detached, { buf, id }) end
      )
      ai_guard.watch_copilot()
    end)
    after_each(function()
      restore_clients()
      restore_detach()
    end)

    describe('filter_copilot', function()
      local sent, client
      before_each(function()
        sent = {}
        client = setmetatable({ name = 'copilot' }, {
          __index = {
            notify = function(_, method)
              table.insert(sent, method)
              return true
            end,
          },
        })
        ai_guard.filter_copilot(client)
      end)

      it('sends an ordinary change', function()
        local buf = h.buffer({ name = plain, lines = { 'local a = 1' } })
        client:notify('textDocument/didChange', {}, buf)
        assert.same({ 'textDocument/didChange' }, sent)
      end)

      it('drops the change that carries a credential, and detaches', function()
        local buf = h.buffer({
          name = plain,
          lines = { 'local token = "ghp_0123456789abcdefghij"' },
        })
        assert.is_true(client:notify('textDocument/didChange', {}, buf))
        assert.same({}, sent)
        vim.wait(500, function() return #detached > 0 end, 10)
        assert.same({ { buf, 42 } }, detached)
      end)

      it('drops a credential sent without a buffer number', function()
        local buf = h.buffer({
          name = plain,
          lines = { 'local token = "ghp_0123456789abcdefghij"' },
        })
        local params = { textDocument = { uri = vim.uri_from_bufnr(buf) } }
        assert.is_true(client:notify('textDocument/didChange', params))
        assert.same({}, sent)
      end)

      it('names the project policy when that is why it detaches', function()
        h.write(dir .. '/kept/.nvim/ai.json', { '{ "local_only": true }' })
        local buf =
          h.buffer({ name = dir .. '/kept/main.lua', lines = { 'local a' } })
        assert.is_true(client:notify('textDocument/didChange', {}, buf))
        vim.wait(500, function() return #detached > 0 end, 10)
        assert.same({ { buf, 42 } }, detached)
        assert.is_true(refused())
        for _, note in ipairs(notes) do
          assert.is_nil(note.msg:find('sensitive', 1, true), note.msg)
        end
      end)

      it('lets the close through', function()
        local buf = h.buffer({ name = secret })
        client:notify('textDocument/didClose', {}, buf)
        assert.same({ 'textDocument/didClose' }, sent)
      end)

      it('wraps a client once', function()
        local wrapped = rawget(client, 'notify')
        ai_guard.filter_copilot(client)
        assert.are.equal(wrapped, rawget(client, 'notify'))
      end)
    end)

    it('detaches Copilot once a buffer turns sensitive', function()
      local buf = h.buffer({ name = plain })
      vim.api.nvim_buf_call(
        buf,
        function() vim.cmd('silent file ' .. secret) end
      )
      assert.same({ { buf, 42 } }, detached)
      assert.is_true(refused())
    end)

    it('detaches Copilot when the filetype makes a buffer sensitive', function()
      local buf = h.buffer({ name = plain })
      vim.bo[buf].filetype = 'gitcommit'
      assert.same({ { buf, 42 } }, detached)
    end)

    it('logs Copilot attaching to a buffer', function()
      local restore = h.stub(
        vim.lsp,
        'get_client_by_id',
        function(id) return { id = id, name = 'copilot' } end
      )
      local buf = h.buffer({ name = plain })
      vim.api.nvim_exec_autocmds(
        'LspAttach',
        { buffer = buf, data = { client_id = 42 } }
      )
      restore()
      assert.same({ 'Copilot sent ' .. plain .. ' (attached)' }, audited())
    end)

    it('leaves an ordinary buffer attached', function()
      local buf = h.buffer({ name = plain })
      vim.bo[buf].filetype = 'lua'
      assert.same({}, detached)
    end)

    --- Fire `event` for `buf` and wait for the debounced check behind it
    ---@param event string
    ---@param buf integer
    local function settle(event, buf)
      vim.api.nvim_exec_autocmds(event, { buffer = buf })
      vim.wait(2000, function() return #detached > 0 end, 20)
    end

    it('detaches Copilot once a credential is typed into a buffer', function()
      local buf = h.buffer({ name = plain, lines = { 'local a = 1' } })
      settle('TextChanged', buf)
      assert.same({}, detached)

      vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
        'local token = "ghp_0123456789abcdefghij"',
      })
      settle('TextChanged', buf)
      assert.same({ { buf, 42 } }, detached)
      assert.is_true(refused())
    end)

    it('offers the buffer back once the credential is gone', function()
      local buf = h.buffer({
        name = plain,
        lines = { 'token = "ghp_0123456789abcdefghij"' },
      })
      settle('TextChanged', buf)
      assert.same({ { buf, 42 } }, detached)

      local reconsidered, set_up_again = 0, 0
      -- Where `vim.lsp.enable` starts its servers from, and where the rest of
      -- a buffer's setup (ftplugins, `util.lazy_install`) hangs
      local lsp =
        vim.api.nvim_create_augroup('nvim.lsp.enable', { clear = false })
      local id = vim.api.nvim_create_autocmd('FileType', {
        group = lsp,
        buffer = buf,
        callback = function() reconsidered = reconsidered + 1 end,
      })
      local other = vim.api.nvim_create_augroup('dy_spec_reattach', {})
      vim.api.nvim_create_autocmd('FileType', {
        group = other,
        buffer = buf,
        callback = function() set_up_again = set_up_again + 1 end,
      })
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'nothing here' })
      vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
      vim.wait(2000, function() return reconsidered > 0 end, 20)
      vim.api.nvim_del_autocmd(id)
      vim.api.nvim_del_augroup_by_id(other)
      assert.are.equal(1, reconsidered)
      assert.are.equal(0, set_up_again)
    end)

    it('leaves a buffer it never took Copilot from alone', function()
      local buf = h.buffer({ name = plain, lines = { 'nothing here' } })
      local reconsidered = 0
      local group = vim.api.nvim_create_augroup('dy_spec_reattach', {})
      vim.api.nvim_create_autocmd('FileType', {
        group = group,
        buffer = buf,
        callback = function() reconsidered = reconsidered + 1 end,
      })
      settle('TextChanged', buf)
      vim.wait(300)
      vim.api.nvim_del_augroup_by_id(group)
      assert.are.equal(0, reconsidered)
      assert.same({}, detached)
    end)

    it('detaches Copilot once betterleaks reports a finding', function()
      local buf = h.buffer({ name = plain, lines = { 'nothing to see' } })
      vim.diagnostic.set(vim.api.nvim_create_namespace('betterleaks'), buf, {
        {
          lnum = 0,
          col = 0,
          severity = vim.diagnostic.severity.WARN,
          source = 'betterleaks',
          code = 'generic-api-key',
          message = 'Detected a generic API key',
        },
      })
      settle('DiagnosticChanged', buf)
      assert.same({ { buf, 42 } }, detached)
    end)
  end)

  describe('commands', function()
    local sensitive

    before_each(function()
      sensitive = require('util.sensitive')
      ai_guard.commands()
    end)

    --- The last message `:AiGuard*` notified
    ---@return string
    local function said() return (notes[#notes] or {}).msg or '' end

    it('says when nothing holds a buffer back', function()
      edit(plain)
      vim.cmd('DyAiGuardCheck')
      assert.is_truthy(said():find('Nothing holding', 1, true))
    end)

    it('names what holds a buffer back', function()
      edit(plain)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        'token = "ghp_0123456789abcdefghij"',
      })
      vim.cmd('DyAiGuardCheck')
      assert.is_truthy(said():find('GitHub token on line 1', 1, true))
    end)

    it('waives the content check, and takes it back with a bang', function()
      edit(plain)
      vim.api.nvim_buf_set_lines(0, 0, -1, false, {
        'token = "ghp_0123456789abcdefghij"',
      })
      vim.cmd('DyAiGuardAllow')
      assert.is_false(sensitive.is_sensitive(0))

      vim.cmd('DyAiGuardCheck')
      assert.is_truthy(said():find('Waived by :DyAiGuardAllow', 1, true))

      vim.cmd('DyAiGuardAllow!')
      assert.is_true(sensitive.is_sensitive(0))
      assert.is_truthy(said():find('back on', 1, true))
    end)

    it('refuses to waive a file sensitive by its name', function()
      edit(secret)
      vim.cmd('DyAiGuardAllow')
      assert.is_true(sensitive.is_sensitive(0))
      assert.is_truthy(said():find('sensitive by its name', 1, true))
    end)
  end)

  describe('setup', function()
    it('installs only the Copilot watch without lazy.nvim', function()
      package.preload['lazy.core.config'] = function() error('no lazy.nvim') end
      local ok = pcall(ai_guard.setup)
      package.preload['lazy.core.config'] = nil
      assert.is_true(ok)
      assert.is_true(
        #vim.api.nvim_get_autocmds({ group = 'dy_ai_guard_copilot' }) > 0
      )
      assert.same(
        {},
        vim.api.nvim_get_autocmds({ event = 'User', pattern = 'LazyLoad' })
      )
    end)

    it('guards a loaded plugin now and the others when they load', function()
      local guarded = {}
      for _, name in ipairs({
        'guard_avante',
        'guard_sidekick',
        'guard_claudecode',
      }) do
        ai_guard[name] = function() table.insert(guarded, name) end
      end
      package.loaded['lazy.core.config'] = {
        plugins = {
          ['avante.nvim'] = { _ = { loaded = true } },
          ['sidekick.nvim'] = { _ = {} },
        },
      }
      ai_guard.setup()
      assert.same({ 'guard_avante' }, guarded)

      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'LazyLoad', data = 'other' }
      )
      assert.same({ 'guard_avante' }, guarded)
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'LazyLoad', data = 'claudecode.nvim' }
      )
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'LazyLoad', data = 'sidekick.nvim' }
      )
      assert.same(
        { 'guard_avante', 'guard_claudecode', 'guard_sidekick' },
        guarded
      )

      -- Each autocmd removes itself once it ran
      vim.api.nvim_exec_autocmds(
        'User',
        { pattern = 'LazyLoad', data = 'sidekick.nvim' }
      )
      assert.equals(3, #guarded)
    end)
  end)

  describe('plugin/ai_guard.lua', function()
    it('sets the guards up at startup', function()
      pcall(vim.api.nvim_del_augroup_by_name, 'dy_ai_guard_copilot')
      dofile(h.root .. '/plugin/ai_guard.lua')
      assert.is_true(
        #vim.api.nvim_get_autocmds({ group = 'dy_ai_guard_copilot' }) > 0
      )
    end)
  end)
end)
