local h = require('helpers')

describe('plugin/breaking', function()
  local calls, restore
  before_each(function()
    calls = {}
    restore = h.stub(package.loaded, 'tools.breaking', {
      diff = function(bufnr, rev) table.insert(calls, { 'diff', bufnr, rev }) end,
      attach = function(bufnr) table.insert(calls, { 'attach', bufnr }) end,
    })
    dofile(h.root .. '/plugin/breaking.lua')
  end)
  after_each(function()
    restore()
    vim.api.nvim_del_user_command('DyBreaking')
    vim.api.nvim_del_augroup_by_name('dy_breaking')
    vim.cmd('silent! %bwipeout!')
  end)

  it('diffs the buffer against the revision given, HEAD unless', function()
    vim.cmd('DyBreaking')
    vim.cmd('DyBreaking v1.0')
    assert.same({ { 'diff', 0 }, { 'diff', 0, 'v1.0' } }, calls)
  end)

  it('attaches to a Protobuf or GraphQL buffer', function()
    local proto = h.buffer({ filetype = 'proto' })
    local graphql = h.buffer({ filetype = 'graphql' })
    h.buffer({ filetype = 'json' })
    assert.same({ { 'attach', proto }, { 'attach', graphql } }, calls)
  end)
end)
