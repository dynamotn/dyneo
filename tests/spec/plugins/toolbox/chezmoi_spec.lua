local h = require('helpers')

describe('plugins.toolbox.chezmoi', function()
  local restores

  --- The specs the file returns, keyed by plugin name, with the chezmoi
  --- plugins turned on or off
  ---@param enabled boolean
  ---@return table<string, table>
  local function load(enabled)
    DyNeo.enabled_plugins.chezmoi = enabled
    local found = {}
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/toolbox/chezmoi.lua')) do
      if type(spec[1]) == 'string' then
        found[spec[1]] = spec
      else
        -- The specs only extended when chezmoi is there
        for _, nested in ipairs(spec) do
          found[nested[1]] = nested
        end
      end
    end
    return found
  end

  before_each(function()
    h.globals()
    restores = {}
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    pcall(vim.api.nvim_del_augroup_by_name, 'chezmoi_plain_partials')
    vim.cmd('silent! %bwipeout!')
  end)

  it('leaves the other plugins alone without chezmoi', function()
    local specs = load(false)
    assert.is_false(specs['xvzc/chezmoi.nvim'].enabled)
    assert.is_false(specs['dpezto/chezmoi-template.nvim'].enabled)
    assert.is_nil(specs['folke/snacks.nvim'])
    assert.is_nil(specs['nvim-mini/mini.icons'])
    local opts = { sources = { providers = {} } }
    assert.is_nil(specs['blink.cmp'].opts(nil, opts))
    assert.same({ sources = { providers = {} } }, opts)
    assert.is_nil(DyNeo.completion_sources.chezmoi)
  end)

  it('completes chezmoi data in templates', function()
    local blink = load(true)['blink.cmp']
    local opts = {}
    blink.opts(nil, opts)
    assert.are.equal('「CZ」', DyNeo.completion_sources.chezmoi)
    assert.are.equal(
      'chezmoi-template.blink',
      opts.sources.providers.chezmoi.module
    )
    assert.are.equal('chezmoi', opts.sources.per_filetype.gotmpl[1])
    assert.is_true(vim.list_contains(opts.sources.per_filetype.gotmpl, 'lsp'))
  end)

  describe('picker', function()
    local picked, edited, closed

    before_each(function()
      picked, edited, closed = nil, nil, false
      table.insert(
        restores,
        h.stub(_G, 'Snacks', {
          picker = { pick = function(opts) picked = opts end },
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'chezmoi.commands', {
          edit = function(opts) edited = opts end,
        })
      )
    end)

    it('streams the managed files in and edits the one picked', function()
      local specs = load(true)
      local key = specs['xvzc/chezmoi.nvim'].keys[1]
      assert.are.equal('<leader>sz', key[1])
      key[2]()
      assert.are.equal('Chezmoi', picked.title)

      local proc_opts
      table.insert(
        restores,
        h.stub(package.loaded, 'snacks.picker.source.proc', {
          proc = function(opts, ctx)
            proc_opts = opts
            return ctx
          end,
        })
      )
      local ctx = { opts = function(_, opts) return opts end }
      assert.are.equal(ctx, picked.finder(nil, ctx))
      assert.are.equal('chezmoi', proc_opts.cmd)
      assert.are.equal('managed', proc_opts.args[1])
      assert.is_true(vim.list_contains(proc_opts.args, 'absolute'))
      local item = { text = '/home/me/.zshrc' }
      proc_opts.transform(item)
      assert.are.equal('/home/me/.zshrc', item.file)

      picked.confirm({ close = function() closed = true end }, item)
      assert.is_true(closed)
      assert.same(
        { targets = { '/home/me/.zshrc' }, args = { '--watch' } },
        edited
      )
    end)

    it("takes the dashboard's config entry over", function()
      local specs = load(true)
      local snacks = specs['folke/snacks.nvim']
      local pick = specs['xvzc/chezmoi.nvim'].keys[1][2]

      local keys =
        { { key = 'f' }, { key = 'c', desc = 'Config' }, { key = 'q' } }
      snacks.opts(nil, { dashboard = { preset = { keys = keys } } })
      assert.are.equal(3, #keys)
      assert.are.equal('c', keys[2].key)
      assert.are.equal(pick, keys[2].action)

      -- Appended when the preset has no config entry
      keys = { { key = 'f' } }
      snacks.opts(nil, { dashboard = { preset = { keys = keys } } })
      assert.are.equal(2, #keys)
      assert.are.equal(pick, keys[2].action)

      -- Nothing to add to without a preset
      local opts = {}
      assert.is_nil(snacks.opts(nil, opts))
      assert.same({}, opts)
    end)
  end)

  describe('plain partials', function()
    local dir, cleanup

    before_each(function()
      dir, cleanup = h.tmpdir()
      load(true)['dpezto/chezmoi-template.nvim'].init()
    end)
    after_each(function() cleanup() end)

    --- The filetype a buffer of `name` ends up with, as a `gotmpl` one
    ---@param name string
    ---@param lines? string[]
    ---@param target? string What the plugin seeded
    ---@return string
    local function typed(name, lines, target)
      local bufnr = h.buffer({ name = name, lines = lines or { 'plain' } })
      vim.b[bufnr].chezmoi_target_lang = target
      vim.bo[bufnr].filetype = 'gotmpl'
      return vim.bo[bufnr].filetype
    end

    it('hands a partial with no action its own filetype', function()
      assert.are.equal(
        'markdown',
        typed(dir .. '/.chezmoitemplates/ai/rules.md')
      )
      assert.are.equal(
        'json',
        typed(dir .. '/.chezmoitemplates/dytoy/pkg', nil, 'json')
      )
    end)

    it('keeps the templates that template', function()
      assert.are.equal(
        'gotmpl',
        typed(dir .. '/.chezmoitemplates/ai/rules.md', { '{{ .name }}' })
      )
      assert.are.equal(
        'gotmpl',
        typed(dir .. '/.chezmoitemplates/ai/rules.md.tmpl')
      )
      assert.are.equal('gotmpl', typed(dir .. '/dot_config/rules.md'))
      assert.are.equal('gotmpl', typed(dir .. '/.chezmoitemplates/noext'))
    end)
  end)

  describe('injection', function()
    local directive, setup_opts, registered, metadata

    before_each(function()
      registered = {}
      table.insert(
        restores,
        h.stub(package.loaded, 'chezmoi-template', {
          setup = function(opts) setup_opts = opts end,
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'chezmoi-template.inject', {
          register_directive = function() error('replaced') end,
        })
      )
      table.insert(
        restores,
        h.stub(package.loaded, 'chezmoi-template.resolve', {
          source_set = function() return { 'every', 'file' } end,
          resolve_path = function(path) return path:gsub('executable_', '') end,
        })
      )
      table.insert(
        restores,
        h.stub(vim.treesitter.query, 'add_directive', function(name, fn, opts)
          table.insert(registered, { name = name, opts = opts })
          directive = fn
        end)
      )
      -- Only the parsers Neovim ships are there to inject
      table.insert(
        restores,
        h.stub(vim.treesitter.language, 'add', function(lang)
          if lang ~= 'lua' then error('no parser for ' .. lang) end
          return true
        end)
      )
      local spec = load(true)['dpezto/chezmoi-template.nvim']
      spec.config(nil, spec.opts)
      metadata = {}
    end)

    it('registers a directive that never injects a tree into itself', function()
      assert.are.equal(setup_opts.apply.on_save, false)
      assert.is_nil(require('chezmoi-template.resolve').source_set())
      assert.same(
        { { name = 'inject-chezmoi!', opts = { force = true } } },
        registered
      )
      require('chezmoi-template.inject').register_directive()
      assert.are.equal(2, #registered)

      local bufnr = h.buffer({ name = 'x.sh.tmpl', filetype = 'gotmpl' })
      vim.b[bufnr].chezmoi_target_lang = 'gotmpl'
      directive(nil, nil, bufnr, nil, metadata)
      assert.same({}, metadata)
    end)

    it('injects the seeded target language when its parser is there', function()
      local bufnr = h.buffer({ name = 'x.lua.tmpl', filetype = 'gotmpl' })
      vim.b[bufnr].chezmoi_target_lang = 'lua'
      directive(nil, nil, bufnr, nil, metadata)
      assert.same(
        { ['injection.language'] = 'lua', ['injection.combined'] = true },
        metadata
      )

      vim.b[bufnr].chezmoi_target_lang = 'cobol'
      metadata = {}
      directive(nil, nil, bufnr, nil, metadata)
      assert.same({}, metadata)
    end)

    it('falls back to the attribute-stripped name of the buffer', function()
      local bufnr = h.buffer({ name = 'executable_x.lua', filetype = 'gotmpl' })
      vim.api.nvim_set_current_buf(bufnr)
      -- Asked without a buffer: the current one
      directive(nil, nil, {}, nil, metadata)
      assert.are.equal('lua', metadata['injection.language'])

      local plain = h.buffer({ name = 'noext', filetype = 'gotmpl' })
      metadata = {}
      directive(nil, nil, plain, nil, metadata)
      assert.same({}, metadata)
    end)
  end)
end)
