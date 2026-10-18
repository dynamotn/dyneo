local h = require('helpers')

describe('plugin/helm', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.helm', {
      value = function() table.insert(calls, 'value') end,
      show_usages = function() table.insert(calls, 'usages') end,
      unused = function(bufnr) table.insert(calls, { 'unused', bufnr }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/helm.lua')
  end)
  after_each(function()
    restore()
    for _, name in ipairs({ 'DyHelmValue', 'DyHelmUsages', 'DyHelmUnused' }) do
      vim.api.nvim_del_user_command(name)
    end
    vim.api.nvim_del_augroup_by_name('dy_helm')
    vim.cmd('silent! %bwipeout!')
  end)

  it('maps each command onto the tool', function()
    vim.cmd('DyHelmValue')
    vim.cmd('DyHelmUsages')
    vim.cmd('DyHelmUnused')
    assert.same({ 'value', 'usages', { 'unused', 0 } }, calls)
  end)

  it('attaches to a template and to the values of a chart', function()
    local template = h.buffer({ filetype = 'helm' })
    local values = h.buffer({ filetype = 'yaml.helm-values' })
    h.buffer({ filetype = 'yaml' })
    assert.same({ { 'attach', template }, { 'attach', values } }, calls)
  end)
end)
