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
