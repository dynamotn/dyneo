local h = require('helpers')

describe('plugin/ci_inline', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.ci_inline', {
      command = function(args) table.insert(calls, { 'command', args.fargs }) end,
      lint = function(bufnr) table.insert(calls, { 'lint', bufnr }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/ci_inline.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyCiStatus')
    vim.api.nvim_del_user_command('DyCiLint')
    vim.api.nvim_del_augroup_by_name('dy_ci_inline')
    vim.cmd('silent! %bwipeout!')
  end)

  it('shows the pipeline, and clears it', function()
    vim.cmd('DyCiStatus')
    vim.cmd('DyCiStatus clear')
    assert.same({ { 'command', {} }, { 'command', { 'clear' } } }, calls)
    assert.same({ 'clear' }, vim.fn.getcompletion('DyCiStatus ', 'cmdline'))
  end)

  it('has GitLab check the current buffer', function()
    vim.cmd('DyCiLint')
    assert.same({ { 'lint', 0 } }, calls)
  end)

  it('attaches to a pipeline or a workflow', function()
    local gitlab = h.buffer({ filetype = 'yaml.gitlab' })
    local workflow = h.buffer({ filetype = 'yaml.gh-action' })
    h.buffer({ filetype = 'yaml' })
    assert.same({ { 'attach', gitlab }, { 'attach', workflow } }, calls)
  end)
end)
