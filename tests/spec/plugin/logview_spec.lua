local h = require('helpers')

describe('plugin/logview', function()
  local calls, restore, dir, cleanup
  before_each(function()
    calls = {}
    dir, cleanup = h.tmpdir()
    restore = h.stub(package.loaded, 'tools.logview', {
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/logview.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyLog')
    cleanup()
  end)

  it('hands the command its words', function()
    vim.cmd('DyLog kube web-1')
    assert.same({ { 'kube', 'web-1' } }, calls)
  end)

  it('completes a source or a file first, nothing after', function()
    h.write(dir .. '/journal.log', { 'x' })
    assert.same(
      vim.list_extend({ 'journal', 'kube' }, vim.fn.getcompletion('', 'file')),
      vim.fn.getcompletion('DyLog ', 'cmdline')
    )
    local lead = vim.fn.fnameescape(dir .. '/jo')
    assert.same(
      { dir .. '/journal.log' },
      vim.fn.getcompletion('DyLog ' .. lead, 'cmdline')
    )
    assert.same({}, vim.fn.getcompletion('DyLog kube ', 'cmdline'))
  end)
end)
