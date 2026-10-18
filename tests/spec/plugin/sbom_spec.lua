local h = require('helpers')

describe('plugin/sbom', function()
  local calls, restore, dir, cleanup
  before_each(function()
    calls = {}
    dir, cleanup = h.tmpdir()
    restore = h.stub(package.loaded, 'tools.sbom', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/sbom.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DySbom')
    cleanup()
  end)

  it('hands the command its subcommand', function()
    vim.cmd('DySbom osv')
    assert.same({ { 'osv' } }, calls)
  end)

  it('completes a subcommand or a file to write', function()
    h.write(dir .. '/out.json', { '{}' })
    assert.same(
      vim.list_extend({ 'osv', 'lock' }, vim.fn.getcompletion('', 'file')),
      vim.fn.getcompletion('DySbom ', 'cmdline')
    )
    assert.same({ 'osv' }, vim.fn.getcompletion('DySbom o', 'cmdline'))
    assert.same(
      { dir .. '/out.json' },
      vim.fn.getcompletion(
        'DySbom ' .. vim.fn.fnameescape(dir .. '/ou'),
        'cmdline'
      )
    )
  end)
end)
