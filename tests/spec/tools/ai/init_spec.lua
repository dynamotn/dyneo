local h = require('helpers')

describe('tools.ai', function()
  local ai, dir, cleanup, restores, notes, audit, asked, sent, sensitive

  before_each(function()
    dir, cleanup = h.tmpdir()
    notes, audit, asked, sent = {}, {}, {}, {}
    sensitive = false
    _G.DyNeo.ai = { target = 'avante', local_providers = { 'ollama' } }
    restores = {
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(package.loaded, 'util.sensitive', {
        is_sensitive = function() return sensitive end,
        reasons = function() return { 'named like a key file' } end,
      }),
      h.stub(package.loaded, 'util.ai_audit', {
        record_buffer = function(_, action, _, detail)
          table.insert(audit, { action, detail })
          return true
        end,
        record = function(_, action, _, detail)
          table.insert(audit, { action, detail })
          return true
        end,
      }),
      h.stub(package.loaded, 'avante.config', { provider = 'claude-code' }),
      h.stub(package.loaded, 'avante.api', {
        ask = function(opts) table.insert(asked, opts) end,
      }),
      h.stub(package.loaded, 'sidekick.cli', {
        send = function(opts) table.insert(sent, opts) end,
      }),
      h.stub(package.loaded, 'util.project_rtp', {
        current = function() return nil end,
      }),
    }
    h.unload('tools.ai', 'tools.ai.prompts', 'util.ai_policy')
    ai = require('tools.ai')
    require('tools.ai.prompts').BUILTIN = dir
    h.write(dir .. '/explain.md', { 'Explain {selection}' })
    h.write(dir .. '/ask.md', { '{input}: {selection}' })
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    _G.DyNeo.ai = nil
    vim.cmd('silent! %bwipeout!')
    cleanup()
  end)

  local function code_buffer()
    local bufnr = h.buffer({ name = dir .. '/a.lua', lines = { 'x', 'y' } })
    vim.api.nvim_set_current_buf(bufnr)
    return bufnr
  end

  it('asks Avante with the expanded prompt and logs it', function()
    code_buffer()
    assert.is_true(ai.run('explain', { 2, 2 }))
    assert.equals(1, #asked)
    assert.is_truthy(asked[1].question:find('Explain ```', 1, true))
    assert.is_truthy(asked[1].question:find('\ny\n', 1, true))
    assert.is_true(asked[1].without_selection)
    assert.same({ { 'sent', 'explain 2-2' } }, audit)
  end)

  it('sends to the sidekick CLI as text, not as a template', function()
    DyNeo.ai.target = 'sidekick'
    local bufnr = code_buffer()
    assert.is_true(ai.send('one {file}\ntwo', bufnr))
    assert.same({ { { 'one {file}' } }, { { 'two' } } }, sent[1].text)
    assert.is_nil(sent[1].msg)
    assert.is_true(sent[1].submit)
  end)

  it('keeps a sensitive buffer from AI and says why', function()
    sensitive = true
    local bufnr = code_buffer()
    assert.is_false(ai.send('text', bufnr))
    assert.same({}, asked)
    assert.equals('refused', audit[1][1])
    assert.is_truthy(notes[1]:find('named like a key file', 1, true))
  end)

  it('refuses a target it does not know', function()
    DyNeo.ai.target = 'other'
    assert.is_false(ai.send('text', code_buffer()))
    assert.same({}, asked)
    assert.same({}, audit)
  end)

  it('warns about a prompt that does not exist', function()
    code_buffer()
    assert.is_false(ai.run('nope'))
    assert.is_truthy(notes[1]:find('nope', 1, true))
  end)

  it('asks for {input} first, and sends nothing when cancelled', function()
    code_buffer()
    local answer = 'why'
    table.insert(
      restores,
      h.stub(vim.ui, 'input', function(_, on_confirm) on_confirm(answer) end)
    )
    ai.run('ask')
    assert.is_truthy(asked[1].question:find('^why: '))
    answer = nil
    ai.run('ask')
    assert.equals(1, #asked)
  end)

  it('runs a prompt over the range of the command', function()
    code_buffer()
    ai.command({ fargs = { 'explain' }, range = 2, line1 = 1, line2 = 1 })
    assert.is_truthy(asked[1].question:find('(lines 1-1)', 1, true))
  end)

  it('hands `commit` to tools.ai.commit', function()
    local written = 0
    table.insert(
      restores,
      h.stub(package.loaded, 'tools.ai.commit', {
        write = function() written = written + 1 end,
      })
    )
    ai.command({ fargs = { 'commit' }, range = 0 })
    assert.equals(1, written)
  end)

  it('completes subcommands and prompt names', function()
    assert.same({ 'explain' }, ai.complete('ex'))
    assert.same({ 'commit' }, ai.complete('comm'))
    assert.same({}, ai.complete('', 'DyAi pr '))
  end)

  it('lists the prompts before the other actions', function()
    local Plugin = require('util.plugin')
    table.insert(restores, h.stub(Plugin, 'has', function() return true end))
    local items = ai.items()
    assert.equals('ask', items[1].name)
    assert.equals('explain', items[2].name)
    assert.equals(2 + #ai.ACTIONS, #items)
    assert.equals(2, #ai.items(nil, true))
  end)

  it('leaves out the actions of a plugin that is not set up', function()
    local Plugin = require('util.plugin')
    table.insert(
      restores,
      h.stub(Plugin, 'has', function(name) return name ~= 'mcphub.nvim' end)
    )
    local names = vim.tbl_map(function(item) return item.name end, ai.items())
    assert.is_false(vim.list_contains(names, 'MCP Hub'))
    assert.is_true(vim.list_contains(names, 'Toggle Claude Code'))
    -- Every action that needs a plugin says which
    for _, action in ipairs(ai.ACTIONS) do
      if not vim.list_contains({ 'Git', 'CI', 'Guard' }, action.group) then
        assert.is_string(action.plugin, action.name)
      end
    end
  end)

  it('warns when the code was cut to fit the prompt', function()
    code_buffer()
    require('tools.ai.prompts').MAX_BYTES = 2
    assert.is_true(ai.run('explain'))
    assert.equals(1, #asked)
    assert.is_truthy(notes[1]:find('cut at 0 KiB', 1, true))
  end)

  it('hands every other subcommand to its module', function()
    local calls = {}
    local function record_call(name)
      return function(arg) table.insert(calls, { name, arg }) end
    end
    for _, stub in ipairs({
      { 'tools.ai.review', 'staged' },
      { 'tools.ai.pr', 'describe' },
      { 'tools.ai.ci', 'explain' },
    }) do
      table.insert(
        restores,
        h.stub(package.loaded, stub[1], { [stub[2]] = record_call(stub[1]) })
      )
    end
    ai.command({ fargs = { 'staged' }, range = 0 })
    ai.command({ fargs = { 'pr', 'feat/x' }, range = 0 })
    ai.command({ fargs = { 'ci' }, range = 0 })
    assert.same({
      { 'tools.ai.review' },
      { 'tools.ai.pr', 'feat/x' },
      { 'tools.ai.ci' },
    }, calls)
  end)

  describe('model', function()
    local avante, api, calls

    before_each(function()
      calls = {}
      api = { select_acp_model = function() table.insert(calls, 'select') end }
      avante = {
        sidebar_open = false,
        is_sidebar_open = function() return avante.sidebar_open end,
        open_sidebar = function() table.insert(calls, 'open') end,
        get = function() return avante.sidebar end,
      }
      table.insert(restores, h.stub(package.loaded, 'avante.api', api))
      table.insert(restores, h.stub(package.loaded, 'avante', avante))
      table.insert(
        restores,
        h.stub(package.loaded, 'avante.config', {
          provider = 'claude-code',
          acp_providers = { ['claude-code'] = {} },
        })
      )
      -- Waiting is what is under test, not the clock: a try follows at once
      table.insert(restores, h.stub(vim, 'defer_fn', function(fn) fn() end))
    end)

    it("leaves one of Avante's own providers to :AvanteModels", function()
      package.loaded['avante.config'].provider = 'ollama'
      vim.api.nvim_create_user_command(
        'AvanteModels',
        function() table.insert(calls, 'models') end,
        {}
      )
      ai.command({ fargs = { 'model' }, range = 0 })
      vim.api.nvim_del_user_command('AvanteModels')
      assert.same({ 'models' }, calls)
    end)

    it('opens the sidebar and picks once the agent lists models', function()
      local client = { config_options = { 'x' } }
      avante.sidebar = {
        acp_client = client,
        chat_history = { acp_session_id = 's1' },
      }
      ai.avante_model()
      assert.same({ 'open', 'select' }, calls)
    end)

    it('says when the connected agent offers no model', function()
      avante.sidebar_open = true
      avante.sidebar = {
        acp_client = { is_ready = function() return true end },
        chat_history = { acp_session_id = 's1' },
      }
      ai.avante_model()
      assert.same({}, calls)
      assert.is_truthy(notes[1]:find('no model to pick', 1, true))
    end)

    it('keeps trying while the agent connects, then gives up', function()
      avante.sidebar_open = true
      local tries = 0
      avante.get = function()
        tries = tries + 1
        -- Connected on the third look, with a model to pick
        if tries == 3 then
          return {
            acp_client = { config_options = {} },
            chat_history = { acp_session_id = 's1' },
          }
        end
        return { acp_client = { is_ready = function() return false end } }
      end
      ai.avante_model()
      assert.same({ 'select' }, calls)
      assert.equals(3, tries)

      tries, calls = 0, {}
      avante.get = function()
        tries = tries + 1
        return nil
      end
      ai.avante_model()
      assert.same({}, calls)
      assert.equals(151, tries)
      assert.is_truthy(notes[#notes]:find('did not connect', 1, true))
    end)
  end)

  describe('picker', function()
    local spec, closed

    before_each(function()
      spec, closed = nil, 0
      table.insert(
        restores,
        h.stub(_G, 'Snacks', {
          picker = { pick = function(s) spec = s end },
        })
      )
      local Plugin = require('util.plugin')
      table.insert(restores, h.stub(Plugin, 'has', function() return true end))
    end)

    it(
      'lists every action, aligned by group, and runs the chosen one',
      function()
        code_buffer()
        ai.command({ fargs = {}, range = 0 })
        assert.equals('AI', spec.title)
        assert.equals(2 + #ai.ACTIONS, #spec.items)
        local line = spec.format(spec.items[1])
        assert.equals('Prompt  ', line[1][1])
        assert.equals('ask', line[3][1])
        local picker = { close = function() closed = closed + 1 end }
        spec.confirm(picker, spec.items[2])
        assert.equals(1, closed)
        vim.wait(1000, function() return #asked > 0 end, 10)
        assert.equals(1, #asked)
        assert.is_truthy(asked[1].question:find('Explain', 1, true))
        -- Dismissed with nothing chosen
        spec.confirm(picker, nil)
        assert.equals(2, closed)
      end
    )

    it('shows the prompts alone on `prompts`', function()
      ai.command({ fargs = { 'prompts' }, range = 0 })
      assert.equals('AI Prompts', spec.title)
      assert.equals(2, #spec.items)
    end)
  end)

  describe('in a project keeping AI local', function()
    before_each(
      function() h.write(dir .. '/.nvim/ai.json', { '{ "local_only": true }' }) end
    )

    it('asks Avante only on a local provider', function()
      local bufnr = code_buffer()
      assert.is_false(ai.deliver('text', bufnr, 'x'))
      assert.same({}, asked)
      assert.equals('refused', audit[1][1])
      assert.is_truthy(notes[1]:find('ollama', 1, true))
      package.loaded['avante.config'].provider = 'ollama'
      assert.is_true(ai.deliver('text', bufnr, 'x'))
      assert.equals(1, #asked)
    end)

    it('sends nothing to the CLIs of sidekick', function()
      DyNeo.ai.target = 'sidekick'
      assert.is_false(ai.deliver('text', dir .. '/a.lua'))
      assert.same({}, sent)
    end)
  end)

  describe('headless', function()
    local checked, answer

    before_each(function()
      checked, answer = {}, nil
      table.insert(
        restores,
        h.stub(package.loaded, 'tools.ai.check', {
          text = function(_, _, text, on_done)
            table.insert(checked, text)
            on_done(text:find('SECRET', 1, true) and 'it holds a SECRET' or nil)
          end,
        })
      )
      local cli = dir .. '/bin/writer'
      h.write(cli, { '#!/bin/sh', 'cat > /dev/null', 'echo written' })
      vim.fn.setfperm(cli, 'rwxr-xr-x')
      DyNeo.ai.commit_command = { cli }
    end)

    --- Run `headless` over `text`, and wait until it has answered or said why
    local function run(text)
      local before = #notes
      ai.headless(text, dir, 'commit message', function(a) answer = a end)
      vim.wait(
        5000,
        function() return answer ~= nil or #notes > before + 1 end,
        10
      )
    end

    it('checks the whole prompt, and refuses what it finds', function()
      run('Branch: feat/SECRET\ndiff')
      assert.same({ 'Branch: feat/SECRET\ndiff' }, checked)
      assert.is_nil(answer)
      assert.same({ { 'refused', 'commit message' } }, audit)
      assert.is_truthy(notes[#notes]:find('Kept from AI', 1, true))
    end)

    it('runs the command once the prompt passes', function()
      run('Branch: feat/two\ndiff')
      assert.equals('written\n', answer)
      assert.same({ { 'sent', 'commit message' } }, audit)
    end)

    it('logs what the command did, once it has run', function()
      h.write(DyNeo.ai.commit_command[1], { '#!/bin/sh', 'exit 3' })
      run('diff')
      assert.same({ { 'sent', 'commit message (failed)' } }, audit)

      audit = {}
      DyNeo.ai.commit_command = { dir .. '/bin/none' }
      run('diff')
      assert.same({}, audit)
    end)

    it('checks the paths it is given, and says why it failed', function()
      local paths, failed
      restores[#restores + 1] = h.stub(package.loaded, 'tools.ai.check', {
        text = function(_, given, _, on_done)
          paths = given
          on_done('a.env is kept from AI')
        end,
      })
      ai.headless('diff', dir, 'review', function(a) answer = a end, {
        paths = { 'a.env', 'b.lua' },
        on_fail = function(reason) failed = reason end,
      })
      assert.same({ 'a.env', 'b.lua' }, paths)
      assert.is_nil(answer)
      assert.equals('Kept from AI: a.env is kept from AI', failed)
    end)

    it('says when the command failed', function()
      h.write(DyNeo.ai.commit_command[1], { '#!/bin/sh', 'exit 3' })
      local failed
      ai.headless('diff', dir, 'review', function(a) answer = a end, {
        on_fail = function(reason) failed = reason end,
      })
      vim.wait(5000, function() return failed ~= nil end, 10)
      assert.is_nil(answer)
      assert.is_truthy(failed)
    end)

    it('says when the command answered nothing', function()
      h.write(
        DyNeo.ai.commit_command[1],
        { '#!/bin/sh', 'cat > /dev/null', 'echo', 'echo " "' }
      )
      run('diff')
      assert.is_nil(answer)
      assert.same({ { 'sent', 'commit message' } }, audit)
      assert.is_truthy(notes[#notes]:find('empty answer', 1, true))
    end)
  end)

  describe('status', function()
    it('says nothing before Avante has loaded', function()
      table.insert(restores, h.stub(package.loaded, 'avante.config', nil))
      assert.is_nil(ai.status())
    end)

    it('names the provider and model, and whether it answers', function()
      table.insert(
        restores,
        h.stub(package.loaded, 'avante.config', {
          provider = 'ollama',
          providers = { ollama = { model = 'qwen' } },
          acp_providers = {},
        })
      )
      local sidebar = { current_state = 'generating' }
      table.insert(
        restores,
        h.stub(package.loaded, 'avante', {
          sidebars = { [vim.api.nvim_get_current_tabpage()] = sidebar },
        })
      )
      assert.same({ 'ollama/qwen', true }, { ai.status() })
      sidebar.current_state = 'succeeded'
      assert.same({ 'ollama/qwen', false }, { ai.status() })
    end)

    it('leaves the model of an ACP agent to the agent', function()
      table.insert(
        restores,
        h.stub(package.loaded, 'avante.config', {
          provider = 'claude-code',
          providers = {},
          acp_providers = { ['claude-code'] = {} },
        })
      )
      assert.equals('claude-code', (ai.status()))
    end)
  end)
end)
