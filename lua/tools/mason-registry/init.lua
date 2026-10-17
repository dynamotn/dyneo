local M = {}
-- The directory of this very file: under another `NVIM_APPNAME`, or loaded
-- from a worktree or a test run, `stdpath('config')` is some other tree
local scan_path = vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2))
local files = vim.fn.glob(scan_path .. '/*.lua', true, true)

for _, file in ipairs(files) do
  local tool_name = vim.fn.fnamemodify(file, ':t:r')
  if tool_name ~= 'init' then
    M = vim.tbl_extend('keep', M, {
      [tool_name] = 'tools.mason-registry.' .. tool_name,
    })
  end
end

-- Packages here may be installed by dytoy (`source.id = 'dytoy:<tool>'`).
-- mason reads this index before it requires any of them, so this is where
-- their ids become purls and where mason learns the package type -- a hook on
-- mason's load could lose the race with an install. Without mason -- the unit
-- tests -- there is nothing to register with, and the packages are left as
-- they are written.
if pcall(require, 'mason-core.installer.compiler') then
  local dytoy = require('tools.mason-dytoy')
  dytoy.register()
  for _, module in pairs(M) do
    dytoy.normalize(require(module))
  end
end

return M
