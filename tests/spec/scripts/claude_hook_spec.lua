local h = require('helpers')

describe('scripts/lib/claude_hook.lua', function()
  local hook

  before_each(
    function() hook = dofile(h.root .. '/scripts/lib/claude_hook.lua') end
  )

  local function decision(event)
    local answer = hook.pre_tool_use(event)
    return answer and answer.hookSpecificOutput.permissionDecision
  end

  describe('before a command', function()
    local function bash(command)
      return decision({ tool_name = 'Bash', tool_input = { command = command } })
    end

    it('refuses to apply chezmoi or skip the hooks', function()
      assert.equals('deny', bash('chezmoi apply ~/.config/nvim'))
      assert.equals('deny', bash('chezmoi  destroy x'))
      assert.equals('deny', bash('git commit --no-verify -m x'))
    end)

    it('refuses to decrypt or reach a credential store', function()
      assert.equals('deny', bash('age -d -i key secrets/x.age'))
      assert.equals('deny', bash('chezmoi-dycrypt'))
      assert.equals('deny', bash('ls ~/Dotfiles/secrets/data/'))
      assert.equals('deny', bash('cat lua/per_machine/encrypted_F1.lua.age'))
      assert.equals('deny', bash('cat "$HOME/.ssh/id_ed25519"'))
      assert.equals('deny', bash('source .envrc'))
    end)

    it('lets the everyday commands through', function()
      assert.is_nil(bash('chezmoi diff'))
      assert.is_nil(bash('scripts/test.sh tests/spec/tools'))
      assert.is_nil(bash("rg -n foo --glob '!*.age' lua"))
      assert.is_nil(bash('cat lua/tools/encrypted.lua'))
      assert.is_nil(bash('rg -n encrypted_ lua'))
      assert.is_nil(bash('page -d x'))
      assert.is_nil(bash('nvim --clean -l scripts/storage.lua'))
    end)
  end)

  describe('before a file is touched', function()
    it('refuses a credential store to every file tool', function()
      for _, tool in ipairs({ 'Read', 'Edit', 'Write', 'Grep', 'Glob' }) do
        assert.equals(
          'deny',
          decision({
            tool_name = tool,
            tool_input = { file_path = '/x/secrets/data/k.yaml' },
          }),
          tool
        )
      end
      assert.equals(
        'deny',
        decision({ tool_name = 'Grep', tool_input = { path = 'secrets/data' } })
      )
      assert.equals(
        'deny',
        decision({ tool_name = 'Read', tool_input = { file_path = '.env' } })
      )
    end)

    it('asks before an edit of a lockfile', function()
      for _, name in ipairs({ 'lazy-lock.json', 'lazy-lock.stable.json' }) do
        assert.equals(
          'ask',
          decision({
            tool_name = 'Edit',
            tool_input = { file_path = '/r/' .. name },
          })
        )
      end
      assert.is_nil(decision({
        tool_name = 'Read',
        tool_input = { file_path = '/r/lazy-lock.json' },
      }))
    end)

    it('lets an ordinary file through', function()
      assert.is_nil(decision({
        tool_name = 'Edit',
        tool_input = { file_path = '/r/lua/tools/encrypted.lua' },
      }))
      assert.is_nil(decision({
        tool_name = 'Read',
        tool_input = { file_path = '/r/tests/spec/literal_encrypted_spec.lua' },
      }))
    end)
  end)

  describe('after an edit of a Lua file', function()
    local root = '/r'

    local function edit(path, old, new)
      return {
        tool_name = 'Edit',
        tool_input = {
          file_path = root .. '/' .. path,
          old_string = old,
          new_string = new,
        },
      }
    end

    it('names what the edit added that AGENTS.md rules out', function()
      local findings = hook.lua_findings(
        edit(
          'lua/tools/x.lua',
          'local a = 1',
          table.concat({
            "vim.keymap.set('n', 'x', 'y')",
            "vim.system({ 'ls' }):wait()",
            '_G.my_setting = 1',
            'LazyVim.root()',
            "vim.cmd('e!')",
          }, '\n')
        ),
        root
      )
      assert.equals(5, #findings)
    end)

    it('says nothing of what was there before the edit', function()
      local text = "vim.keymap.set('n', 'x', 'y')\nlocal a = 1"
      assert.same(
        {},
        hook.lua_findings(
          edit('lua/tools/x.lua', text, text .. '\nlocal b = 2'),
          root
        )
      )
    end)

    it('leaves alone the files whose job is to use them', function()
      assert.same(
        {},
        hook.lua_findings(
          edit('lua/util/system.lua', '', 'proc:wait(100)'),
          root
        )
      )
      assert.same(
        {},
        hook.lua_findings(
          edit('tests/spec/x_spec.lua', '', "vim.keymap.set('n', 'x', 'y')"),
          root
        )
      )
      assert.same(
        {},
        hook.lua_findings(
          edit('lua/tools/x.lua', '', '_G.DyNeo.x = _G.dd and _G.Snacks'),
          root
        )
      )
    end)

    it('compares a rewritten file with what it held before', function()
      local event = {
        tool_name = 'Write',
        tool_input = {
          file_path = root .. '/lua/tools/x.lua',
          content = "vim.keymap.set('n', 'x', 'y')",
        },
        tool_response = { originalFile = "vim.keymap.set('n', 'x', 'y')" },
      }
      assert.same({}, hook.lua_findings(event, root))
      event.tool_response = nil
      assert.equals(1, #hook.lua_findings(event, root))
    end)

    it(
      'reports StyLua and the findings together, and nothing when clean',
      function()
        local answer = hook.post_tool_use(
          edit('lua/tools/x.lua', '', 'LazyVim.x()'),
          root,
          function() return 'StyLua disagrees' end
        )
        assert.equals('block', answer.decision)
        assert.matches('LazyVim is gone', answer.reason)
        assert.matches('StyLua disagrees', answer.reason)
        assert.is_nil(
          hook.post_tool_use(
            edit('lua/tools/x.lua', '', 'local a = 1'),
            root,
            function() end
          )
        )
        assert.is_nil(
          hook.post_tool_use(
            edit('README.md', '', 'LazyVim'),
            root,
            function() return 'x' end
          )
        )
      end
    )
  end)
end)

describe('scripts/claude-hook.lua', function()
  local function run(phase, event)
    local result = vim
      .system({
        vim.v.progpath,
        '--clean',
        '--headless',
        '-l',
        h.root .. '/scripts/claude-hook.lua',
        phase,
      }, { stdin = event, text = true })
      :wait(10000)
    return result.stdout ~= '' and vim.json.decode(result.stdout) or nil
  end

  it('answers a refused command as Claude Code reads it', function()
    local answer = run(
      'pre',
      vim.json.encode({
        tool_name = 'Bash',
        tool_input = { command = 'chezmoi apply' },
      })
    )
    assert.equals('deny', answer.hookSpecificOutput.permissionDecision)
  end)

  it(
    'stays quiet about an ordinary command',
    function()
      assert.is_nil(run(
        'pre',
        vim.json.encode({
          tool_name = 'Bash',
          tool_input = { command = 'ls' },
        })
      ))
    end
  )

  it('refuses when it cannot read the event', function()
    local answer = run('pre', 'not json')
    assert.equals('deny', answer.hookSpecificOutput.permissionDecision)
  end)
end)
