local h = require('helpers')

describe('plugin/adr', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.adr', {
      SUBCOMMANDS = { 'new', 'list', 'status', 'supersede' },
      STATUSES = { 'Proposed', 'Accepted' },
      command = function(args) table.insert(calls, args.fargs) end,
    })
    dofile(h.root .. '/plugin/adr.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyAdr')
  end)

  it('hands the command its arguments', function()
    vim.cmd('DyAdr status 3 accepted')
    assert.same({ { 'status', '3', 'accepted' } }, calls)
  end)

  it(
    'completes the subcommands first',
    function()
      assert.same(
        { 'status', 'supersede' },
        vim.fn.getcompletion('DyAdr s', 'cmdline')
      )
    end
  )

  it(
    'completes a status in lower case after `status`',
    function()
      assert.same(
        { 'proposed', 'accepted' },
        vim.fn.getcompletion('DyAdr status ', 'cmdline')
      )
    end
  )

  it(
    'completes nothing after another subcommand',
    function() assert.same({}, vim.fn.getcompletion('DyAdr list ', 'cmdline')) end
  )
end)
