local h = require('helpers')

describe('plugins.lang.yaml', function()
  local restores, specs

  --- The spec of `name` among those `plugins.lang.yaml` returns
  ---@param name string
  ---@return table
  local function spec(name)
    for _, s in ipairs(specs) do
      if s[1] == name then return s end
    end
    error('no spec ' .. name)
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/lang/yaml.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  it('loads with Ansible as well as YAML', function()
    DyNeo.enabled_languages = { 'ansible' }
    assert.is_true(#dofile(h.root .. '/lua/plugins/lang/yaml.lua') > 0)
    DyNeo.enabled_languages = { 'lua' }
    assert.same({}, dofile(h.root .. '/lua/plugins/lang/yaml.lua'))
  end)

  it(
    'hands the schemas to yamlls as it starts, and picks them by key',
    function()
      local calls = {}
      local schema = require('util.yaml_schema')
      for _, name in ipairs({ 'on_init', 'select', 'reset' }) do
        table.insert(
          restores,
          h.stub(
            schema,
            name,
            function(...) table.insert(calls, { name, ... }) end
          )
        )
      end
      local yamlls = spec('neovim/nvim-lspconfig').opts.servers.yamlls
      yamlls.on_init('client')
      for _, key in ipairs(yamlls.keys) do
        if type(key[2]) == 'function' then key[2]() end
      end
      assert.same({
        { 'on_init', 'client' },
        { 'select' },
        { 'select', 0, true },
        { 'reset', 0 },
      }, calls)
      assert.is_false(yamlls.settings.yaml.schemaStore.enable)
      assert.is_true(yamlls.settings.yaml.kubernetesCRDStore.enable)
      assert.is_true(
        vim.list_contains(
          yamlls.settings.yaml.customTags,
          '!reference sequence'
        )
      )
    end
  )

  it('shows the schema of the buffer in the statusline', function()
    local opts = { sections = { lualine_y = { 'progress' } } }
    spec('nvim-lualine/lualine.nvim').opts(nil, opts)
    local component = opts.sections.lualine_y[1]
    assert.are.equal('progress', opts.sections.lualine_y[2])
    local icon = require('config.defaults').icons.treesitter.schema

    local bufnr = h.buffer({ filetype = 'yaml' })
    vim.api.nvim_set_current_buf(bufnr)
    assert.is_true(component.cond())
    assert.are.equal(icon, component[1]())
    vim.b[bufnr].yaml_schema_name = 'kustomization'
    assert.are.equal(icon .. 'kustomization', component[1]())

    vim.api.nvim_set_current_buf(h.buffer({ filetype = 'lua' }))
    assert.is_false(component.cond())
  end)
end)
