-- Diagnostics are configured in one place, `plugins.lsp.server`. That spec
-- loads on the first file, after tiny-inline-diagnostic's `VeryLazy` when
-- Neovim starts without one, so it must leave the native virtual text off
-- itself whenever tiny-inline draws the messages.
local h = require('helpers')

describe('diagnostics', function()
  local Plugin, restore, has

  --- The resolved options of the nvim-lspconfig spec
  local function lsp_opts()
    for _, spec in ipairs(dofile(h.root .. '/lua/plugins/lsp/server.lua')) do
      if spec[1] == 'neovim/nvim-lspconfig' then return spec.opts(nil, {}) end
    end
  end

  before_each(function()
    h.globals()
    Plugin = require('util.plugin')
    has = {}
    restore = h.stub(Plugin, 'has', function(name) return has[name] == true end)
  end)
  after_each(function() restore() end)

  it('leaves the virtual text to tiny-inline-diagnostic', function()
    has['tiny-inline-diagnostic.nvim'] = true
    assert.is_false(lsp_opts().diagnostics.virtual_text)
  end)

  it(
    'keeps the native virtual text without it',
    function() assert.equals('table', type(lsp_opts().diagnostics.virtual_text)) end
  )

  it('is not configured again by tiny-inline-diagnostic', function()
    local source = table.concat(
      vim.fn.readfile(h.root .. '/lua/plugins/ui/diagnostic.lua'),
      '\n'
    )
    assert.is_nil(source:find('vim.diagnostic.config', 1, true))
  end)
end)

describe('diagnostics: plugins.ui.diagnostic', function()
  local restores, specs

  ---@param name string
  ---@return table
  local function spec_of(name)
    for _, spec in ipairs(specs) do
      if spec[1] == name then return spec end
    end
    error('no spec ' .. name)
  end

  ---@param spec table
  ---@param lhs string
  ---@return table
  local function key_of(spec, lhs)
    for _, key in ipairs(spec.keys) do
      if key[1] == lhs then return key end
    end
    error('no key ' .. lhs)
  end

  before_each(function()
    h.globals()
    restores = {}
    specs = dofile(h.root .. '/lua/plugins/ui/diagnostic.lua')
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
  end)

  it('sets up and toggles tiny-inline-diagnostic', function()
    local calls = {}
    table.insert(
      restores,
      h.stub(package.loaded, 'tiny-inline-diagnostic', {
        setup = function(opts) table.insert(calls, { 'setup', opts }) end,
        toggle = function() table.insert(calls, { 'toggle' }) end,
      })
    )
    local spec = spec_of('rachartier/tiny-inline-diagnostic.nvim')
    spec.config()
    key_of(spec, '<leader>uv')[2]()
    assert.same({ { 'setup' }, { 'toggle' } }, calls)
  end)

  it('acts on the rule behind a diagnostic from its keys', function()
    local calls = {}
    table.insert(
      restores,
      h.stub(
        package.loaded,
        'rulebook',
        setmetatable({}, {
          __index = function(_, name)
            return function() table.insert(calls, name) end
          end,
        })
      )
    )
    local spec = spec_of('chrisgrieser/nvim-rulebook')
    for _, lhs in ipairs({
      '<leader>ci',
      '<leader>cI',
      '<leader>cY',
      '<leader>cZ',
    }) do
      key_of(spec, lhs)[2]()
    end
    assert.same(
      { 'ignoreRule', 'lookupRule', 'yankDiagnosticCode', 'suppressFormatter' },
      calls
    )
  end)

  it('writes the ignore comment in the comment of the buffer', function()
    local ignore = spec_of('chrisgrieser/nvim-rulebook').opts().ignoreComments
    -- dyshellint and shfmt share one directive
    assert.equals(ignore.dyshellint, ignore.shfmt)
    assert.equals('# dyshellint disable=%s', ignore.shfmt.comment)

    local bufnr = h.buffer({})
    vim.api.nvim_set_current_buf(bufnr)
    vim.bo[bufnr].commentstring = '-- %s'
    assert.equals(
      '-- biome-ignore lint/style/noVar: explanation',
      ignore.biomejs.comment({ code = 'lint/style/noVar' })
    )
    assert.equals('-- betterleaks:allow', ignore.betterleaks.comment({}))
    assert.is_true(ignore.betterleaks.doesNotUseCodes)
    assert.equals(
      '-- trivy:ignore:AVD-AWS-0001',
      ignore.trivy.comment({ code = 'AVD-AWS-0001' })
    )
    vim.bo[bufnr].commentstring = '# %s'
    assert.equals('# betterleaks:allow', ignore.betterleaks.comment({}))
  end)
end)
