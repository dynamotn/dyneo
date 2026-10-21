-- Temporary: trace what keymaps-doc spawns, and say every 10 s whether the
-- main loop still runs and what is still running
local start = vim.uv.hrtime()
local running = {}
local function note(msg)
  io.stderr:write(
    ('[trace %6.2f] %s\n'):format((vim.uv.hrtime() - start) / 1e9, msg)
  )
end

local function show(cmd)
  return type(cmd) == 'table' and table.concat(cmd, ' '):sub(1, 200)
    or tostring(cmd):sub(1, 200)
end

local spawn = vim.uv.spawn
vim.uv.spawn = function(cmd, opts, on_exit)
  local line = show({ cmd, unpack((opts or {}).args or {}) })
  note('spawn ' .. line)
  running[line] = (running[line] or 0) + 1
  return spawn(cmd, opts, function(...)
    running[line] = running[line] - 1
    if running[line] == 0 then running[line] = nil end
    note('exit ' .. line .. ' code=' .. tostring((...)))
    if on_exit then return on_exit(...) end
  end)
end
local jobstart = vim.fn.jobstart
vim.fn.jobstart = function(cmd, ...)
  note('jobstart ' .. show(cmd))
  return jobstart(cmd, ...)
end
for _, name in ipairs({ 'system', 'systemlist' }) do
  local f = vim.fn[name]
  vim.fn[name] = function(cmd, ...)
    note('fn.' .. name .. ' ' .. show(cmd))
    return f(cmd, ...)
  end
end

local timer = assert(vim.uv.new_timer())
timer:start(
  10000,
  10000,
  function()
    note('alive; still running: ' .. vim.inspect(vim.tbl_keys(running)))
  end
)
timer:unref()

vim.api.nvim_create_autocmd({ 'VimLeavePre', 'VimLeave', 'UIEnter' }, {
  callback = function(ev) note('event ' .. ev.event) end,
})
vim.api.nvim_create_autocmd('User', {
  pattern = { 'VeryLazy', 'LazyDone', 'LazyLoad' },
  callback = function(ev) note('User ' .. ev.match .. ' ' .. tostring(ev.data)) end,
})
