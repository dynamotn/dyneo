local M = {}

---@param increment boolean
---@param g? boolean
function M.dial(increment, g)
  local mode = vim.fn.mode(true)
  -- Use visual commands for VISUAL 'v', VISUAL LINE 'V' and VISUAL BLOCK '\22'
  local is_visual = mode == 'v' or mode == 'V' or mode == '\22'
  local func = (increment and 'inc' or 'dec')
    .. (g and '_g' or '_')
    .. (is_visual and 'visual' or 'normal')
  local group = require('util.languages').get_language_from_filetype(
    vim.bo.filetype
  ) or 'default'
  return require('dial.map')[func](group)
end

return {
  -- Increment and decrement numbers, dates, and more
  'monaqa/dial.nvim',
  keys = {
    {
      '<C-a>',
      function() return M.dial(true) end,
      expr = true,
      desc = 'Increment',
      mode = { 'n', 'v' },
    },
    {
      '<C-x>',
      function() return M.dial(false) end,
      expr = true,
      desc = 'Decrement',
      mode = { 'n', 'v' },
    },
    {
      'g<C-a>',
      function() return M.dial(true, true) end,
      expr = true,
      desc = 'Increment',
      mode = { 'n', 'v' },
    },
    {
      'g<C-x>',
      function() return M.dial(false, true) end,
      expr = true,
      desc = 'Decrement',
      mode = { 'n', 'v' },
    },
  },
  opts = function()
    local opts = { groups = {} }
    local augend = require('dial.augend')
    -- Rules per filetype
    for name, language in pairs(require('config.languages')) do
      if name == '*' then
        opts.groups.default = language.dial(augend)
      elseif language.dial then
        opts.groups[name] = language.dial(augend)
      else
        opts.groups[name] = {}
      end
    end
    return opts
  end,
  config = function(_, opts)
    -- An augend the installed dial.nvim lacks is nil: an older release on the
    -- stable channel, or a newer one still held in quarantine. It is left
    -- out, where dial would refuse the whole group, and the mappings with it.
    for name, group in pairs(opts.groups) do
      local kept = {}
      for i = 1, table.maxn(group) do
        if group[i] ~= nil then kept[#kept + 1] = group[i] end
      end
      opts.groups[name] = kept
    end
    -- copy defaults to each group
    for name, group in pairs(opts.groups) do
      if name ~= 'default' then vim.list_extend(group, opts.groups.default) end
    end
    require('dial.config').augends:register_group(opts.groups)
  end,
}
