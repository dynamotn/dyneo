local h = require('helpers')

describe('plugins.integration.ai', function()
  --- The spec of `name` in the plugin file
  ---@param name string
  ---@return table
  local function spec_of(name)
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/integration/ai.lua')) do
      if plugin[1] == name then return plugin end
    end
    error('no spec for ' .. name)
  end

  it('builds Avante before its optional adapters', function()
    local build = spec_of('yetone/avante.nvim').build
    assert.are.equal('make', build[1])
  end)

  it('installs adapters and MCP Hub at pinned versions', function()
    for _, name in ipairs({ 'yetone/avante.nvim', 'ravitemer/mcphub.nvim' }) do
      local build = spec_of(name).build
      for _, step in ipairs(type(build) == 'table' and build or { build }) do
        if type(step) == 'string' then
          assert.is_nil(step:find('@latest', 1, true), step)
        end
      end
    end
  end)

  it(
    'warns rather than fails when the agy ACP server cannot install',
    function()
      local notes = {}
      local restores = {
        h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
        h.stub(
          vim.uv,
          'os_uname',
          function() return { sysname = 'Plan9', machine = 'mips' } end
        ),
      }
      local ok = pcall(spec_of('yetone/avante.nvim').build[3])
      for _, restore in ipairs(restores) do
        restore()
      end
      assert.is_true(ok)
      assert.are.equal(1, #notes)
    end
  )

  it('asks before an ACP agent reads, searches or edits', function()
    local approved =
      spec_of('yetone/avante.nvim').opts.behaviour.auto_approve_tool_permissions
    -- ACP tool kinds carry no path, so none of these may pass unasked
    for _, kind in ipairs({ 'read', 'search', 'edit', 'delete', 'move' }) do
      assert.is_false(vim.list_contains(approved, kind), kind)
    end
    for _, kind in ipairs({ 'execute', 'fetch', 'other' }) do
      assert.is_false(vim.list_contains(approved, kind), kind)
    end
  end)
end)

describe('plugins.integration.ai: specs driven', function()
  local restores, specs

  --- The spec of `name`
  ---@param name string
  ---@return table
  local function spec_of(name)
    for _, plugin in ipairs(specs) do
      if plugin[1] == name then return plugin end
    end
    error('no spec for ' .. name)
  end

  --- Run the callback of key `lhs` of `plugin`, in `mode` when given
  ---@param plugin table
  ---@param lhs string
  ---@param mode? string
  local function press(plugin, lhs, mode)
    for _, key in ipairs(plugin.keys) do
      if
        key[1] == lhs
        and type(key[2]) == 'function'
        and (not mode or vim.list_contains(key.mode or { 'n' }, mode))
      then
        return key[2]()
      end
    end
    error('no callback for ' .. lhs)
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/integration/ai.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('declines Copilot a sensitive or local-only buffer', function()
    local root_dir =
      spec_of('neovim/nvim-lspconfig').opts.servers.copilot.root_dir
    local plain = h.buffer({ name = '/tmp/dy/plain.lua', lines = { 'x' } })
    local secret = h.buffer({ name = '/tmp/dy/secret.lua', lines = { 'x' } })
    require('util.sensitive').mark(secret, 'decrypted with sops')
    local calls = 0
    root_dir(plain, function() calls = calls + 1 end)
    assert.equals(1, calls)
    root_dir(secret, function() calls = calls + 1 end)
    assert.equals(1, calls)
    table.insert(
      restores,
      h.stub(
        require('util.ai_policy'),
        'local_only',
        function() return true end
      )
    )
    root_dir(plain, function() calls = calls + 1 end)
    assert.equals(1, calls)
  end)

  it('turns inline completion on, and wires its keys', function()
    local selected, got, enabled = {}, 0, false
    table.insert(
      restores,
      h.stub(vim.lsp, 'inline_completion', {
        select = function(opts) table.insert(selected, opts.count) end,
        get = function()
          got = got + 1
          return true
        end,
        enable = function() enabled = true end,
      })
    )
    local copilot = spec_of('neovim/nvim-lspconfig').opts.servers.copilot
    for _, key in ipairs(copilot.keys) do
      key[2]()
    end
    assert.same({ 1, -1 }, selected)
    local actions = require('util.cmp').actions
    local before = actions.ai_accept
    spec_of('neovim/nvim-lspconfig').opts.setup.copilot()
    vim.wait(200, function() return enabled end, 5)
    assert.is_true(enabled)
    assert.is_true(actions.ai_accept())
    assert.equals(1, got)
    actions.ai_accept = before
  end)

  it('sets sidekick up for the multiplexer in use, with NES on Tab', function()
    local nes = { enabled = true, have = function() return true end }
    nes.jump = function() return nes.jumped end
    nes.apply = function() return nes.applied end
    nes.enable = function(state) nes.enabled = state end
    local toggles = {}
    table.insert(restores, h.stub(package.loaded, 'sidekick.nes', nes))
    table.insert(
      restores,
      h.stub(_G, 'Snacks', {
        toggle = function(opts)
          table.insert(toggles, opts)
          return {
            map = function(_, lhs) toggles[#toggles].lhs = lhs end,
          }
        end,
      })
    )
    local actions = require('util.cmp').actions
    local before = actions.ai_nes
    local tmux = h.stub(vim.env, 'TMUX', nil)
    local opts = spec_of('folke/sidekick.nvim').opts(nil, {})
    assert.equals('zellij', opts.cli.mux.backend)
    assert.equals('<leader>uN', toggles[1].lhs)
    assert.is_true(toggles[1].get())
    toggles[1].set(false)
    assert.is_false(nes.enabled)

    -- Nothing to jump to or apply: Tab falls through
    assert.is_nil(actions.ai_nes())
    assert.equals('<tab>', press(spec_of('folke/sidekick.nvim'), '<tab>'))
    nes.applied = true
    assert.is_true(press(spec_of('folke/sidekick.nvim'), '<tab>'))
    actions.ai_nes = before

    tmux()
    tmux = h.stub(vim.env, 'TMUX', '/tmp/tmux-1000/default,1,0')
    opts = spec_of('folke/sidekick.nvim').opts(nil, {})
    tmux()
    assert.equals('tmux', opts.cli.mux.backend)
  end)

  it('quotes a file location for the Antigravity CLI', function()
    local transformed
    table.insert(
      restores,
      h.stub(package.loaded, 'sidekick.text', {
        transform = function(text, fn, kind)
          transformed = { text = text, kind = kind, fn = fn }
        end,
      })
    )
    table.insert(restores, h.stub(package.loaded, 'sidekick.nes', {}))
    table.insert(
      restores,
      h.stub(_G, 'Snacks', {
        toggle = function()
          return { map = function() end }
        end,
      })
    )
    local opts = spec_of('folke/sidekick.nvim').opts(nil, {})
    opts.cli.tools.antigravity.format('@a b.lua')
    assert.equals('SidekickLocFile', transformed.kind)
    assert.equals('src/a_b.lua', transformed.fn('src/a_b.lua'))
    assert.equals('"my file.lua"', transformed.fn('my file.lua'))
  end)

  it('drives the sidekick CLI from its keys', function()
    local calls = {}
    local cli = setmetatable({}, {
      __index = function(_, name)
        return function(opts) table.insert(calls, { name, opts }) end
      end,
    })
    table.insert(restores, h.stub(package.loaded, 'sidekick.cli', cli))
    table.insert(
      restores,
      h.stub(package.loaded, 'sidekick.cli.picker.snacks', {
        send = function(...) table.insert(calls, { 'picker', ... }) end,
      })
    )
    local sidekick = spec_of('folke/sidekick.nvim')
    for _, lhs in ipairs({
      '<c-.>',
      '<leader>aa',
      '<leader>as',
      '<leader>ad',
      '<leader>af',
      '<leader>ap',
      '<leader>aD',
    }) do
      press(sidekick, lhs)
    end
    press(sidekick, '<leader>at', 'x')
    press(sidekick, '<leader>aV', 'x')
    spec_of('folke/snacks.nvim').opts.picker.actions.sidekick_send('p', 'i')
    assert.same({
      { 'focus' },
      { 'toggle' },
      { 'select' },
      { 'close' },
      { 'send', { msg = '{file}' } },
      { 'prompt' },
      { 'send', { msg = '{diagnostics}' } },
      { 'send', { msg = '{this}' } },
      { 'send', { msg = '{selection}' } },
      { 'picker', 'p', 'i' },
    }, calls)
  end)

  describe('lualine', function()
    local status, cli, ai_status, ai_busy, components, switched

    before_each(function()
      status, cli, ai_status, ai_busy, switched = nil, {}, nil, false, 0
      table.insert(
        restores,
        h.stub(package.loaded, 'sidekick.status', {
          get = function() return status end,
          cli = function() return cli end,
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'tools.ai', {
          status = function() return ai_status, ai_busy end,
        })
      )
      table.insert(
        restores,
        h.stub(_G, 'Snacks', {
          util = {
            color = function(hl) return '#' .. tostring(hl) end,
          },
        })
      )
      table.insert(
        restores,
        h.stub(
          vim.cmd,
          'AvanteSwitchProvider',
          function() switched = switched + 1 end
        )
      )
      local opts = { sections = { lualine_x = { 'first', 'second' } } }
      spec_of('nvim-lualine/lualine.nvim').opts(nil, opts)
      components = opts.sections.lualine_x
    end)

    it('slots its three components second, keeping the first', function()
      assert.equals('first', components[1])
      assert.equals('second', components[5])
      -- A statusline with nothing yet puts them first
      local opts = {}
      spec_of('nvim-lualine/lualine.nvim').opts(nil, opts)
      assert.equals(3, #opts.sections.lualine_x)
    end)

    it('counts the running CLI sessions', function()
      local sessions = components[2]
      assert.is_false(sessions.cond())
      cli = { {} }
      assert.is_true(sessions.cond())
      assert.matches('^%S+ $', sessions[1]())
      cli = { {}, {} }
      assert.matches('^%S+ 2$', sessions[1]())
      assert.same({ fg = '#Special' }, sessions.color())
    end)

    it('shows the Avante provider, busy while it answers', function()
      local avante = components[3]
      assert.is_false(avante.cond())
      ai_status = 'copilot/claude'
      assert.is_true(avante.cond())
      assert.equals('󰚩 copilot/claude', avante[1]())
      assert.same({ fg = '#Special' }, avante.color())
      ai_busy = true
      assert.same({ fg = '#DiagnosticWarn' }, avante.color())
      avante.on_click()
      assert.equals(1, switched)
    end)

    it('shows the Copilot status by kind, warning while busy', function()
      local copilot = components[4]
      assert.is_false(copilot.cond())
      assert.is_nil(copilot[1]())
      assert.same({ fg = '#nil' }, copilot.color())
      status = { kind = 'Normal' }
      assert.is_true(copilot.cond())
      local normal = copilot[1]()
      assert.matches('^%S+ $', normal)
      assert.same({ fg = '#Special' }, copilot.color())
      status = { kind = 'Error', busy = true }
      assert.matches('^%S+ $', copilot[1]())
      assert.are_not.equal(normal, copilot[1]())
      assert.same({ fg = '#DiagnosticWarn' }, copilot.color())
    end)
  end)

  it('sets Avante up with a global statusline', function()
    local set_up
    table.insert(
      restores,
      h.stub(package.loaded, 'avante', {
        setup = function(opts) set_up = opts end,
        toggle = function() set_up = 'toggled' end,
      })
    )
    local laststatus = vim.o.laststatus
    local avante = spec_of('yetone/avante.nvim')
    avante.config(nil, avante.opts)
    assert.equals(3, vim.o.laststatus)
    vim.o.laststatus = laststatus
    assert.equals(avante.opts, set_up)
    press(avante, '<leader>avc')
    assert.equals('toggled', set_up)
  end)

  it('drives Avante and its model picker from its keys', function()
    local asked, picked = 0, 0
    table.insert(
      restores,
      h.stub(package.loaded, 'avante.api', {
        ask = function() asked = asked + 1 end,
      })
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'tools.ai', {
        avante_model = function() picked = picked + 1 end,
      })
    )
    local avante = spec_of('yetone/avante.nvim')
    press(avante, '<leader>ava', 'v')
    press(avante, '<leader>avm')
    assert.equals(1, asked)
    assert.equals(1, picked)
  end)

  it('turns Ollama on when its server answers', function()
    local alive = false
    table.insert(
      restores,
      h.stub(package.loaded, 'avante.providers.ollama', {
        check_endpoint_alive = function() return alive end,
      })
    )
    local ollama = spec_of('yetone/avante.nvim').opts.providers.ollama
    assert.is_false(ollama.is_env_set())
    alive = true
    assert.is_true(ollama.is_env_set())
  end)

  it('reads the MCP servers on every message, none without MCP Hub', function()
    local opts = spec_of('yetone/avante.nvim').opts
    local missing = {
      h.stub(package.loaded, 'mcphub', nil),
      h.stub(package.preload, 'mcphub', function() error('not installed') end),
      h.stub(
        package.preload,
        'mcphub.extensions.avante',
        function() error('not installed') end
      ),
    }
    assert.equals('', opts.system_prompt())
    assert.same({}, opts.custom_tools())
    for i = #missing, 1, -1 do
      missing[i]()
    end

    local hub
    table.insert(
      restores,
      h.stub(package.loaded, 'mcphub', {
        get_hub_instance = function() return hub end,
      })
    )
    table.insert(
      restores,
      h.stub(package.loaded, 'mcphub.extensions.avante', {
        mcp_tool = function() return 'tool' end,
      })
    )
    -- Hub loaded but not started yet
    assert.equals('', opts.system_prompt())
    hub = {
      get_active_servers_prompt = function() return 'servers: fs' end,
    }
    assert.equals('servers: fs', opts.system_prompt())
    assert.same({ 'tool' }, opts.custom_tools())
  end)

  it('names the Avante completion source', function()
    DyNeo.completion_sources = { LSP = 'lsp' }
    spec_of('Kaiser-Yang/blink-cmp-avante').init()
    assert.same({ LSP = 'lsp', Avante = '「AI」' }, DyNeo.completion_sources)
  end)
end)

describe('plugins.integration.ai: agy ACP server install', function()
  local dir, cleanup, restores, notes, path, build

  --- A script on the private `$PATH`
  ---@param name string
  ---@param lines string[]
  local function script(name, lines)
    h.write(dir .. '/bin/' .. name, vim.list_extend({ '#!/bin/sh' }, lines))
    vim.fn.setfperm(dir .. '/bin/' .. name, 'rwxr-xr-x')
  end

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    notes = {}
    path = vim.env.PATH
    vim.env.PATH = dir .. '/bin'
    local stdpath = vim.fn.stdpath
    restores = {
      h.stub(vim.fn, 'stdpath', function(what)
        if what == 'data' then return dir .. '/data' end
        return stdpath(what)
      end),
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
      h.stub(
        vim.uv,
        'os_uname',
        function() return { sysname = 'Linux', machine = 'x86_64' } end
      ),
    }
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/integration/ai.lua')) do
      if plugin[1] == 'yetone/avante.nvim' then build = plugin.build[3] end
    end
  end)
  after_each(function()
    vim.env.PATH = path
    for i = #restores, 1, -1 do
      restores[i]()
    end
    cleanup()
  end)

  it('downloads and unpacks the archive, then drops it', function()
    script('curl', { 'echo "$@" > "' .. dir .. '/data/curl.log"', ': > "$3"' })
    script('unzip', { 'echo "$@" > "$5/unzip.log"' })
    build()
    assert.same({}, notes)
    local curl = vim.fn.readfile(dir .. '/data/curl.log')[1]
    assert.truthy(
      curl:find('agy-acp-server-1.2.1-linux-x86_64.zip', 1, true),
      curl
    )
    assert.truthy(curl:find('/releases/linux/', 1, true), curl)
    assert.equals(1, vim.fn.filereadable(dir .. '/data/agy-acp/unzip.log'))
    assert.equals(0, vim.fn.filereadable(dir .. '/data/agy-acp.zip'))
  end)

  it('warns when the download fails, and goes no further', function()
    script('curl', { 'echo "no route" >&2', 'exit 7' })
    script('unzip', { 'echo "$@" > "$5/unzip.log"' })
    build()
    assert.equals(1, #notes)
    assert.truthy(notes[1]:find('curl', 1, true), notes[1])
    assert.truthy(notes[1]:find('no route', 1, true), notes[1])
    assert.equals(0, vim.fn.filereadable(dir .. '/data/agy-acp/unzip.log'))
  end)
end)
