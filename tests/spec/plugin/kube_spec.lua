local h = require('helpers')

-- `plugin/kube.lua` keeps its own copy of the detection, so a YAML buffer
-- that holds nothing for a cluster never loads `tools.kube`; the two must
-- still agree on every buffer
describe('plugin/kube', function()
  local dir, cleanup

  before_each(function()
    dir, cleanup = h.tmpdir()
    h.write(dir .. '/chart/Chart.yaml', { 'name: chart' })
    h.unload('tools.kube')
  end)
  after_each(function()
    vim.cmd('silent! %bwipeout!')
    h.unload('tools.kube')
    cleanup()
  end)

  ---@param n integer
  ---@return string[]
  local function filler(n)
    local lines = {}
    for i = 1, n do
      lines[i] = ('x%d: 1'):format(i)
    end
    return lines
  end

  local cases = {
    { name = 'pod.yaml', lines = { 'apiVersion: v1', 'kind: Pod' } },
    { name = 'pod.yaml', lines = { 'apiVersion: v1' } },
    { name = 'pod.yaml', lines = { '  apiVersion: v1', '  kind: Pod' } },
    {
      name = 'late.yaml',
      lines = vim.list_extend(filler(198), { 'apiVersion: v1', 'kind: Pod' }),
    },
    {
      name = 'later.yaml',
      lines = vim.list_extend(filler(199), { 'apiVersion: v1', 'kind: Pod' }),
    },
    { name = 'kustomization.yaml', lines = { 'resources: []' } },
    { name = 'Kustomization.yml', lines = { 'resources: []' } },
    { name = 'chart/values.yaml', lines = { 'replicas: 1' } },
    { name = 'chart/templates/deploy.yaml', lines = { '{{ .Values }}' } },
    { name = 'compose.yaml', lines = { 'services: {}' } },
  }

  for i, case in ipairs(cases) do
    it(
      ('agrees with the module on case %d (%s)'):format(i, case.name),
      function()
        local kube = require('tools.kube')
        local attached = {}
        local restore = h.stub(
          kube,
          'attach',
          function(bufnr) attached[bufnr] = true end
        )
        dofile(h.root .. '/plugin/kube.lua')
        local bufnr =
          h.buffer({ name = dir .. '/' .. case.name, lines = case.lines })
        vim.bo[bufnr].filetype = 'yaml'
        restore()
        assert.equals(kube.is_kube(bufnr), attached[bufnr] == true)
      end
    )
  end

  it('completes the subcommands of the module, sorted', function()
    dofile(h.root .. '/plugin/kube.lua')
    local names = vim.tbl_keys(require('tools.kube').SUBCOMMANDS)
    table.sort(names)
    assert.same(names, vim.fn.getcompletion('DyKube ', 'cmdline'))
    local lead = names[1]:sub(1, 1)
    local expected = vim.tbl_filter(
      function(name) return name:sub(1, 1) == lead end,
      names
    )
    assert.same(expected, vim.fn.getcompletion('DyKube ' .. lead, 'cmdline'))
  end)

  it('does not load the module for YAML of no cluster', function()
    dofile(h.root .. '/plugin/kube.lua')
    local bufnr =
      h.buffer({ name = dir .. '/compose.yaml', lines = { 'services: {}' } })
    vim.bo[bufnr].filetype = 'yaml'
    assert.is_nil(package.loaded['tools.kube'])
  end)
end)
