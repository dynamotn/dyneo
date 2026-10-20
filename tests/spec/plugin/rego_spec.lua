local h = require('helpers')

describe('plugin/rego', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.rego', {
      SUBCOMMANDS = { 'test', 'clear' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/rego.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyRego')
  end)

  it('hands :DyRego its input or subcommand', function()
    vim.cmd('DyRego input.yaml')
    vim.cmd('DyRego test')
    assert.same({ { 'input.yaml' }, { 'test' } }, calls)
  end)

  it('completes its subcommands before files', function()
    local found = vim.fn.getcompletion('DyRego ', 'cmdline')
    assert.same({ 'test', 'clear' }, vim.list_slice(found, 1, 2))
    -- A file that starts alike follows: `tests/`
    assert.equals('test', vim.fn.getcompletion('DyRego te', 'cmdline')[1])
  end)
end)
