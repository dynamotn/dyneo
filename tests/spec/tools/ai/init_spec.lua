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
