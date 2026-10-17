local h = require('helpers')

describe('plugins.integration.ai', function()
  --- The spec of `name` in the plugin file
  ---@param name string
  ---@return table
  local function spec_of(name)
    for _, plugin in ipairs(dofile(h.root .. '/lua/plugins/integration/ai.lua')) do
      if plugin[1] == name then return plugin end
    end
    error('no spec for ' .. name)
  end

  it('builds Avante before its optional adapters', function()
    local build = spec_of('yetone/avante.nvim').build
    assert.are.equal('make', build[1])
  end)

  it(
    'warns rather than fails when the agy ACP server cannot install',
    function()
      local notes = {}
      local restores = {
        h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end),
        h.stub(
          vim.uv,
          'os_uname',
          function() return { sysname = 'Plan9', machine = 'mips' } end
        ),
      }
      local ok = pcall(spec_of('yetone/avante.nvim').build[3])
      for _, restore in ipairs(restores) do
        restore()
      end
      assert.is_true(ok)
      assert.are.equal(1, #notes)
    end
  )

  it('asks before an ACP agent reads, searches or edits', function()
    local approved =
      spec_of('yetone/avante.nvim').opts.behaviour.auto_approve_tool_permissions
    -- ACP tool kinds carry no path, so none of these may pass unasked
    for _, kind in ipairs({ 'read', 'search', 'edit', 'delete', 'move' }) do
      assert.is_false(vim.list_contains(approved, kind), kind)
    end
    for _, kind in ipairs({ 'execute', 'fetch', 'other' }) do
      assert.is_false(vim.list_contains(approved, kind), kind)
    end
  end)
end)
