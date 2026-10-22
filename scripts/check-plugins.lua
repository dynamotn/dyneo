-- Fail when a plugin of this configuration is not installed, or not on the
-- commit the lockfile names, and name it.
--
-- `:Lazy! restore` exits 0 even when a clone failed, so a host being down
-- -- Codeberg answering 503 -- only shows up later, as the configuration
-- failing to load for a reason that no longer mentions the plugin. And when
-- the start before it installs a plugin the cache lacks, lazy.nvim writes the
-- lockfile from what the cache had checked out, so the restore puts a stale
-- cache back rather than the lockfile. Run after the configuration is loaded,
-- with the lockfile as committed:
--
--   nvim --headless -c 'luafile scripts/check-plugins.lua'

local Config = require('lazy.core.config')
local Git = require('lazy.manage.git')

local lock = {} ---@type table<string, { commit: string }>
local file = io.open(Config.options.lockfile, 'r')
if file then
  local ok, decoded = pcall(vim.json.decode, file:read('*a'))
  file:close()
  if ok and type(decoded) == 'table' then lock = decoded end
end

local missing, moved = {}, {} ---@type string[], string[]
for name, plugin in pairs(Config.plugins) do
  if not plugin._.installed then
    table.insert(missing, name)
  elseif not plugin._.is_local and lock[name] then
    local info = Git.info(plugin.dir)
    if not info or info.commit ~= lock[name].commit then
      table.insert(
        moved,
        ('%s (%s, not %s)'):format(
          name,
          info and info.commit:sub(1, 7) or '?',
          lock[name].commit:sub(1, 7)
        )
      )
    end
  end
end
table.sort(missing)
table.sort(moved)

if #missing > 0 then
  io.stderr:write(
    'check-plugins: not installed: ' .. table.concat(missing, ', ') .. '\n'
  )
end
if #moved > 0 then
  io.stderr:write(
    'check-plugins: not on the lockfile: ' .. table.concat(moved, ', ') .. '\n'
  )
end
vim.cmd(#missing + #moved > 0 and 'cquit' or 'qall!')
