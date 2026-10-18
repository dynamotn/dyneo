local h = require('helpers')

describe('plugins.lang.markdown', function()
  local dir, cleanup

  before_each(function()
    h.globals()
    dir, cleanup = h.tmpdir()
    DyNeo.enabled_plugins.obsidian = true
  end)
  after_each(function() cleanup() end)

  --- The obsidian.nvim spec, read with these vaults configured
  ---@param paths table<string, string>
  local function obsidian(paths)
    DyNeo.obsidian.paths = paths
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/markdown.lua')) do
      if spec[1] == 'obsidian-nvim/obsidian.nvim' then return spec end
    end
  end

  it('loads obsidian.nvim for the notes of a vault only', function()
    vim.fn.mkdir(dir .. '/notes', 'p')
    local spec = obsidian({ notes = dir .. '/notes', gone = dir .. '/gone' })
    assert.is_true(spec.enabled)
    assert.is_nil(spec.ft)
    assert.same(
      { { name = 'notes', path = dir .. '/notes' } },
      spec.opts.workspaces
    )
    assert.same({
      'BufReadPre ' .. dir .. '/notes/*.md',
      'BufNewFile ' .. dir .. '/notes/*.md',
    }, spec.event)
  end)

  it(
    'leaves obsidian.nvim out without a vault on this machine',
    function() assert.is_false(obsidian({ gone = dir .. '/gone' }).enabled) end
  )

  it('labels the note completion and opens the todo list', function()
    vim.fn.mkdir(dir .. '/notes', 'p')
    obsidian({ personal = dir .. '/notes' }).init()
    assert.are.equal('「NOTE」', DyNeo.completion_sources.obsidian)

    local scratch
    local restore = h.stub(_G, 'Snacks', {
      scratch = function(opts) scratch = opts end,
    })
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/markdown.lua')) do
      if spec[1] == 'folke/snacks.nvim' then spec.keys[1][2]() end
    end
    restore()
    assert.are.equal('markdown', scratch.ft)
    assert.are.equal(dir .. '/notes/01_Fleeting/TODO.md', scratch.file)
  end)

  describe('markdownlint', function()
    local lint, restore, config_home

    --- The nvim-lint opts hook of the spec, run with `home` as the XDG
    --- config directory
    ---@param home string
    local function run(home)
      vim.env.XDG_CONFIG_HOME = home
      for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lang/markdown.lua')) do
        if spec[1] == 'mfussenegger/nvim-lint' then spec.opts() end
      end
    end

    before_each(function()
      lint = { linters = { ['markdownlint-cli2'] = { args = { '-' } } } }
      restore = h.stub(package.loaded, 'lint', lint)
      config_home = vim.env.XDG_CONFIG_HOME
    end)
    after_each(function()
      restore()
      vim.env.XDG_CONFIG_HOME = config_home
    end)

    it('passes the shared config only when it is there', function()
      run(dir)
      assert.same({ '-' }, lint.linters['markdownlint-cli2'].args)
      h.write(dir .. '/markdownlint/config.yaml', { 'default: true' })
      run(dir)
      assert.same(
        { '--config', dir .. '/markdownlint/config.yaml', '-' },
        lint.linters['markdownlint-cli2'].args
      )
    end)
  end)
end)
