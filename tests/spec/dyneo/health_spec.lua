local h = require('helpers')

--- The entries of the section whose title starts with `prefix`
---@param report table[]
---@param prefix string
---@return table[]
local function section(report, prefix)
  for _, part in ipairs(report) do
    if vim.startswith(part.title, prefix) then return part.entries end
  end
  return {}
end

--- Whether any entry of `entries` is `level` and says `text`
---@param entries table[]
---@param level string
---@param text string
---@return boolean
local function says(entries, level, text)
  for _, item in ipairs(entries) do
    if item.level == level and item.message:find(text, 1, true) then
      return true
    end
  end
  return false
end

--- Run `fn` with the config home pointing at `dir`
---@param dir string
---@param fn fun()
local function with_config_home(dir, fn)
  local before = vim.env.XDG_CONFIG_HOME
  vim.env.XDG_CONFIG_HOME = dir
  local ok, err = pcall(fn)
  vim.env.XDG_CONFIG_HOME = before
  assert.is_true(ok, err)
end

--- A fresh report
---@return table[]
local function report()
  h.unload('dyneo.health')
  return require('dyneo.health').report()
end

describe('dyneo.health', function()
  local dir, cleanup
  before_each(function()
    -- The version gate is `DyNeo.neovim_floor`, declared by `config.globals`
    h.globals()
    dir, cleanup = h.tmpdir()
  end)
  after_each(function() cleanup() end)

  it('reports every section, whatever is loaded', function()
    local titles
    with_config_home(dir, function()
      titles = vim.tbl_map(function(part) return part.title end, report())
    end)
    assert.are.equal(6, #titles)
    assert.are.same(
      { 'DyNeo', 'Requirements', 'nvim-treesitter' },
      { titles[1], titles[2], titles[3] }
    )
    assert.is_true(vim.startswith(titles[4], 'Supply chain quarantine'))
    assert.are.same(
      { 'AI guard', 'Tools from the system' },
      { titles[5], titles[6] }
    )
  end)

  it('checks Neovim against the plugin channel', function()
    local restore = h.stub(DyNeo, 'plugin_channel', 'stable')
    with_config_home(
      dir,
      function()
        assert.is_true(says(section(report(), 'DyNeo'), 'ok', '>= 0.12.0'))
      end
    )
    restore()
  end)

  it('lists what nvim-treesitter needs to build parsers', function()
    with_config_home(dir, function()
      local entries = section(report(), 'nvim-treesitter')
      for _, name in ipairs({ 'tree-sitter (CLI)', 'C compiler', 'tar', 'curl' }) do
        assert.is_true(
          says(entries, 'ok', name) or says(entries, 'error', name),
          name
        )
      end
    end)
  end)

  it('reads the bun and uv windows out of the config home', function()
    h.write(
      dir .. '/.bunfig.toml',
      { '[install]', 'minimumReleaseAge = 604800' }
    )
    h.write(dir .. '/uv/uv.toml', { 'exclude-newer = "7 days"' })
    with_config_home(dir, function()
      local entries = section(report(), 'Supply chain')
      assert.is_true(says(entries, 'ok', 'bun holds a package for 7 days'))
      assert.is_true(says(entries, 'ok', 'uv holds a package for 7 days'))
    end)
  end)

  it('reads bun from the home directory without a config home', function()
    h.write(dir .. '/.bunfig.toml', { 'minimumReleaseAge = 604800' })
    -- `vim.env` reads the environment, so the values are put back by hand
    local xdg, home = vim.env.XDG_CONFIG_HOME, vim.env.HOME
    vim.env.XDG_CONFIG_HOME = nil
    vim.env.HOME = dir
    local ok, entries = pcall(
      function() return section(report(), 'Supply chain') end
    )
    vim.env.XDG_CONFIG_HOME = xdg
    vim.env.HOME = home
    assert.is_true(ok, entries)
    assert.is_true(says(entries, 'ok', 'bun holds a package for 7 days'))
  end)

  it('warns about a window shorter than the quarantine', function()
    h.write(dir .. '/.bunfig.toml', { 'minimumReleaseAge = 3600' })
    h.write(dir .. '/uv/uv.toml', { 'exclude-newer = "1 day"' })
    with_config_home(dir, function()
      local entries = section(report(), 'Supply chain')
      assert.is_true(says(entries, 'warn', 'bun holds a package for 0 days'))
      assert.is_true(says(entries, 'warn', 'uv holds a package for 1 days'))
    end)
  end)

  it('says so when neither tool is configured', function()
    with_config_home(dir, function()
      local entries = section(report(), 'Supply chain')
      assert.is_true(says(entries, 'info', 'No .bunfig.toml'))
      assert.is_true(says(entries, 'info', 'No uv.toml'))
    end)
  end)

  it('reports the lazy.nvim patch as missing until it is put in', function()
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(section(report(), 'Supply chain'), 'error', 'lazy.nvim is not')
        )
      end
    )
  end)

  it('reports the lazy.nvim patch once it is in place', function()
    local Git = require('lazy.manage.git')
    local original = Git.get_target
    h.unload('tools.lazy-quarantine')
    require('tools.lazy-quarantine').setup()
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(section(report(), 'Supply chain'), 'ok', 'Plugin updates wait')
        )
      end
    )
    Git.get_target = original
    h.unload('tools.lazy-quarantine')
  end)

  it('says Mason has not been loaded yet', function()
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(section(report(), 'Supply chain'), 'info', 'mason.nvim is not')
        )
      end
    )
  end)

  it('counts the rules of the AI guard', function()
    local sensitive = require('config.sensitive')
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(
            section(report(), 'AI guard'),
            'info',
            ('%d credential formats'):format(#sensitive.content_patterns)
          )
        )
      end
    )
  end)

  it('names what holds the buffer it was run from back', function()
    local bufnr = h.buffer({
      name = dir .. '/values.yaml',
      lines = { 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz' },
    })
    vim.api.nvim_set_current_buf(bufnr)
    -- `:checkhealth` runs in a buffer of its own
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(section(report(), 'AI guard'), 'info', 'GitHub token on line 1')
        )
      end
    )
    vim.cmd('silent! %bwipeout!')
  end)

  it('reports git, which every machine running this has', function()
    with_config_home(
      dir,
      function()
        assert.is_true(says(section(report(), 'Requirements'), 'ok', 'git'))
      end
    )
  end)

  it('only mentions a tool one command needs, never warns', function()
    local restore = h.stub(vim.fn, 'executable', function(name)
      if name == 'infracost' then return 0 end
      return 1
    end)
    local entries = section(report(), 'Requirements')
    restore()
    assert.is_true(says(entries, 'info', 'infracost is not installed'))
    assert.is_false(says(entries, 'warn', 'infracost'))
  end)

  it('tells mikefarah/yq from the Python yq', function()
    local bin = dir .. '/bin'
    local path = vim.env.PATH
    vim.env.PATH = bin .. ':' .. path
    local function yq(version)
      h.write(bin .. '/yq', { '#!/bin/sh', 'echo "' .. version .. '"' })
      vim.fn.setfperm(bin .. '/yq', 'rwxr-xr-x')
      return section(report(), 'Requirements')
    end
    local go = yq('yq (https://github.com/mikefarah/yq/) version v4.44.3')
    local python = yq('yq 3.4.3')
    vim.env.PATH = path
    assert.is_true(says(go, 'ok', 'yq is mikefarah/yq'))
    assert.is_true(says(python, 'warn', 'yq is not mikefarah/yq (yq 3.4.3)'))
  end)

  it('names the CLIs the encrypted files and Kubernetes run', function()
    local restore = h.stub(vim.fn, 'executable', function() return 0 end)
    local entries = section(report(), 'Requirements')
    restore()
    for _, cli in ipairs({ 'sops', 'ansible-vault', 'kubectl', 'helm' }) do
      assert.is_true(says(entries, 'info', cli .. ' is not installed'), cli)
    end
    assert.is_false(says(entries, 'info', 'hdb'))
  end)

  it('says the Neovim is too old for the channel', function()
    local restore = h.stub(
      DyNeo,
      'neovim_floor',
      function() return '99.0.0' end
    )
    local entries
    with_config_home(dir, function() entries = section(report(), 'DyNeo') end)
    restore()
    assert.is_true(says(entries, 'error', 'Neovim >= 99.0.0 is required'))
  end)

  it('says when git is too old for :DyReview, or cannot tell', function()
    local bin = dir .. '/bin'
    local path = vim.env.PATH
    vim.env.PATH = bin .. ':' .. path
    local function git(version)
      h.write(bin .. '/git', { '#!/bin/sh', 'echo "' .. version .. '"' })
      vim.fn.setfperm(bin .. '/git', 'rwxr-xr-x')
      return section(report(), 'Requirements')
    end
    local old = git('git version 2.39.5')
    local newer = git('git version 3.0.1')
    local garbled = git('no version here')
    vim.env.PATH = path
    assert.is_true(
      says(old, 'error', 'git 2.39 is older than 2.40, which `:DyReview` needs')
    )
    assert.is_true(says(newer, 'ok', 'git is 2.40 or newer'))
    assert.is_true(says(garbled, 'warn', 'git version failed: cannot tell'))
  end)

  it('cannot tell which yq it is when --version fails', function()
    local bin = dir .. '/bin'
    h.write(bin .. '/yq', { '#!/bin/sh', 'exit 1' })
    vim.fn.setfperm(bin .. '/yq', 'rwxr-xr-x')
    local path = vim.env.PATH
    vim.env.PATH = bin .. ':' .. path
    local ok, entries = pcall(section, report(), 'Requirements')
    vim.env.PATH = path
    assert.is_true(ok, entries)
    assert.is_true(says(entries, 'warn', 'yq --version failed'))
  end)

  describe('with mason.nvim loaded', function()
    local settings
    before_each(
      function()
        settings = {
          providers = { 'tools.mason-quarantine' },
          firewall = { enabled = true },
          install_root_dir = dir .. '/mason',
        }
      end
    )

    --- The quarantine section with `mason.settings` answering `settings`
    ---@param info? string What `info.json` of the registry holds
    ---@return table[]
    local function quarantine(info)
      if info then
        h.write(
          dir .. '/mason/registries/github/mason-org/mason-registry/info.json',
          { info }
        )
      end
      local restore = h.stub(package.loaded, 'mason.settings', {
        current = settings,
      })
      local ok, entries = pcall(function()
        local found
        with_config_home(
          dir,
          function() found = section(report(), 'Supply chain') end
        )
        return found
      end)
      restore()
      assert.is_true(ok, entries)
      return entries
    end

    it('reports the quarantine as the only provider', function()
      local entries = quarantine()
      assert.is_true(says(entries, 'ok', 'Mason resolves its registry'))
      assert.is_true(says(entries, 'ok', 'Socket Firewall stands'))
      assert.is_true(says(entries, 'info', 'No registry snapshot'))
    end)

    it('objects to other providers beside the quarantine', function()
      table.insert(settings.providers, 'mason.providers.registry-api')
      assert.is_true(
        says(
          quarantine(),
          'error',
          'lists others beside tools.mason-quarantine'
        )
      )
    end)

    it('objects to a registry resolved without the quarantine', function()
      settings.providers = { 'mason.providers.registry-api' }
      settings.firewall = { enabled = false }
      local entries = quarantine()
      assert.is_true(says(entries, 'error', 'is not in the Mason `providers`'))
      assert.is_true(says(entries, 'warn', 'The Socket Firewall is off'))
    end)

    it('looks for the registry under the data directory by default', function()
      settings.install_root_dir = nil
      local restore = h.stub(vim.fn, 'stdpath', function() return dir end)
      local ok, entries = pcall(quarantine, '{"version": "2024-01-02-abc"}')
      restore()
      assert.is_true(ok, entries)
      assert.is_true(says(entries, 'ok', 'Registry snapshot 2024-01-02-abc'))
    end)

    it('tells the age of the registry snapshot', function()
      local old = quarantine('{"version": "2024-01-02-abc"}')
      assert.is_true(says(old, 'ok', 'Registry snapshot 2024-01-02-abc'))
      local today = os.date('%Y-%m-%d')
      local fresh = quarantine(('{"version": "%s-abc"}'):format(today))
      assert.is_true(says(fresh, 'warn', 'Registry snapshot ' .. today))
    end)

    it('says when the snapshot has no version or no date', function()
      assert.is_true(
        says(quarantine('{}'), 'warn', 'The registry snapshot has no version')
      )
      assert.is_true(
        says(
          quarantine('not json'),
          'warn',
          'The registry snapshot has no version'
        )
      )
      assert.is_true(
        says(
          quarantine('{"version": "v1"}'),
          'info',
          'Registry snapshot v1, of no readable date'
        )
      )
    end)
  end)

  it('reports a lazy quarantine that cannot be loaded', function()
    local restore = h.stub(package.loaded, 'tools.lazy-quarantine', nil)
    package.preload['tools.lazy-quarantine'] = function()
      error('broken on purpose')
    end
    local ok, titles_and_entries = pcall(function()
      local found
      with_config_home(dir, function()
        local parts = report()
        found = { parts[4].title, section(parts, 'Supply chain') }
      end)
      return found
    end)
    package.preload['tools.lazy-quarantine'] = nil
    restore()
    assert.is_true(ok, titles_and_entries)
    -- Without the module the window falls back to a week
    assert.are.equal('Supply chain quarantine (7 days)', titles_and_entries[1])
    assert.is_true(
      says(
        titles_and_entries[2],
        'error',
        'tools.lazy-quarantine cannot be loaded'
      )
    )
  end)

  it('warns about a bun or uv config that sets no window', function()
    h.write(dir .. '/.bunfig.toml', { '[install]' })
    h.write(dir .. '/uv/uv.toml', { '[pip]' })
    with_config_home(dir, function()
      local entries = section(report(), 'Supply chain')
      assert.is_true(
        says(entries, 'warn', '.bunfig.toml sets no `minimumReleaseAge`')
      )
      assert.is_true(says(entries, 'warn', 'uv.toml sets no `exclude-newer`'))
    end)
  end)

  it('repeats a uv window that is a date rather than days', function()
    h.write(dir .. '/uv/uv.toml', { 'exclude-newer = "2024-01-01T00:00:00Z"' })
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(
            section(report(), 'Supply chain'),
            'info',
            'uv holds a package until 2024-01-01T00:00:00Z'
          )
        )
      end
    )
  end)

  it('reports config.languages when it cannot be loaded', function()
    local restore = h.stub(package.loaded, 'config.languages', nil)
    package.preload['config.languages'] = function() error('broken on purpose') end
    local ok, entries = pcall(function()
      local found
      with_config_home(
        dir,
        function() found = section(report(), 'Tools from the system') end
      )
      return found
    end)
    package.preload['config.languages'] = nil
    restore()
    assert.is_true(ok, entries)
    assert.is_true(says(entries, 'error', 'config.languages cannot be loaded'))
  end)

  it('names the tools Mason leaves to the system that are missing', function()
    local restore = h.stub(vim.fn, 'executable', function() return 0 end)
    local ok, entries = pcall(
      function() return section(report(), 'Tools from the system') end
    )
    restore()
    assert.is_true(ok, entries)
    assert.is_true(says(entries, 'info', 'Not on $PATH'))
  end)

  it('says every system tool is there when it is', function()
    local restore = h.stub(vim.fn, 'executable', function() return 1 end)
    local ok, entries = pcall(
      function() return section(report(), 'Tools from the system') end
    )
    restore()
    assert.is_true(ok, entries)
    assert.is_true(says(entries, 'ok', 'Every tool Mason does not install'))
  end)

  it('lists which AI integrations are guarded', function()
    local restore = h.stub(package.loaded, 'util.ai_guard', {
      status = { avante = 'guarded', copilot = 'missing' },
    })
    local ok, entries = pcall(function()
      local found
      with_config_home(
        dir,
        function() found = section(report(), 'AI guard') end
      )
      return found
    end)
    restore()
    assert.is_true(ok, entries)
    assert.is_true(says(entries, 'ok', 'avante is guarded'))
    assert.is_true(says(entries, 'warn', 'copilot was not found'))
    assert.is_false(says(entries, 'info', 'No AI integration has loaded'))
  end)

  it('says a plain buffer may be sent to an AI', function()
    local bufnr = h.buffer({ name = dir .. '/notes.md', lines = { 'hello' } })
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(section(report(), 'AI guard'), 'info', 'may be sent to an AI')
        )
      end
    )
    vim.cmd('silent! %bwipeout!')
  end)

  it('warns about a waived buffer that would be held back', function()
    local bufnr = h.buffer({
      name = dir .. '/values.yaml',
      lines = { 'token: ghp_0123456789abcdefghijklmnopqrstuvwxyz' },
    })
    require('util.sensitive').allow(bufnr)
    vim.api.nvim_set_current_buf(bufnr)
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    with_config_home(
      dir,
      function()
        assert.is_true(
          says(section(report(), 'AI guard'), 'warn', ':DyAiGuardAllow waived')
        )
      end
    )
    vim.cmd('silent! %bwipeout!')
  end)

  it('falls back to the file buffer used last', function()
    local bufnr = h.buffer({ name = dir .. '/last.md', lines = { 'hello' } })
    vim.api.nvim_set_current_buf(bufnr)
    -- Two scratch buffers in a row: the alternate is then a scratch too.
    -- The first holds a line, or `:enew` would reuse it instead of leaving it
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'scratch' })
    vim.cmd.enew()
    vim.bo.buftype = 'nofile'
    assert.are_not.equal(bufnr, vim.fn.bufnr('#'))
    with_config_home(dir, function()
      assert.is_true(
        says(section(report(), 'AI guard'), 'info', 'Buffer checked: ')
      )
      assert.is_true(says(section(report(), 'AI guard'), 'info', 'last.md'))
    end)
    vim.cmd('silent! %bwipeout!')
  end)

  it('prints every section through vim.health', function()
    local calls = {}
    local restores = {}
    for _, name in ipairs({ 'start', 'ok', 'warn', 'error', 'info' }) do
      table.insert(
        restores,
        h.stub(
          vim.health,
          name,
          function(message) table.insert(calls, { name, message }) end
        )
      )
    end
    local ok, err = pcall(function()
      with_config_home(dir, function()
        h.unload('dyneo.health')
        require('dyneo.health').check()
      end)
    end)
    for i = #restores, 1, -1 do
      restores[i]()
    end
    assert.is_true(ok, err)
    local starts = vim.tbl_filter(function(c) return c[1] == 'start' end, calls)
    assert.are.equal(6, #starts)
    assert.are.equal('DyNeo', starts[1][2])
    assert.is_true(#calls > #starts)
  end)
end)
