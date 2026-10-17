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
end)
