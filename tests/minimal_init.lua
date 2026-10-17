-- Bootstrap for the unit tests: this repository and the few plugins the
-- modules under test lean on, and nothing else of the configuration.
--
-- The specs require modules one at a time and stub what they reach for, so
-- the plugin specs are not loaded. Plenary (the test runner) and lazy.nvim
-- (whose `lazy.core` modules `util.plugin` builds on) are taken from
-- lazy.nvim's install directory when the configuration has been started once
-- on this machine, and otherwise fetched next to the tests at the commit
-- `lazy-lock.json` names.
--
--   nvim --headless --noplugin -u tests/minimal_init.lua \
--     -c "PlenaryBustedDirectory tests/spec {minimal_init = 'tests/minimal_init.lua'}"

local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
root = vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))

--- The commit `lazy-lock.json` pins `name` to, so a clone tests against what
--- the configuration runs and not whatever the branch has moved on to
---@param name string
---@return string
local function locked_commit(name)
  local ok, lock = pcall(
    vim.json.decode,
    table.concat(vim.fn.readfile(vim.fs.joinpath(root, 'lazy-lock.json')), '')
  )
  local commit = ok and lock[name] and lock[name].commit
  if not commit then
    io.stderr:write(
      'minimal_init: no commit for ' .. name .. ' in lazy-lock.json\n'
    )
    os.exit(1)
  end
  return commit
end

--- Run git, and quit with its output when it fails
---@param args string[]
local function git(args)
  local out = vim.fn.system(vim.list_extend({ 'git' }, args))
  if vim.v.shell_error ~= 0 then
    io.stderr:write(
      ('minimal_init: git %s failed\n%s'):format(table.concat(args, ' '), out)
    )
    os.exit(1)
  end
  return vim.trim(out)
end

---@param name string Directory name under lazy.nvim's root
---@param url string Where to clone it from when it is missing
---@return string
local function dependency(name, url)
  local installed =
    vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'lazy', name)
  if vim.uv.fs_stat(installed) then return installed end
  local local_copy = vim.fs.joinpath(root, '.tests', name)
  local commit = locked_commit(name)
  if not vim.uv.fs_stat(local_copy) then
    git({ 'init', '--quiet', local_copy })
    git({ '-C', local_copy, 'remote', 'add', 'origin', url })
  end
  -- A fresh repository has no `HEAD` yet, which is not an error here
  local head = vim.fn.system({ 'git', '-C', local_copy, 'rev-parse', 'HEAD' })
  if vim.trim(head) ~= commit then
    git({ '-C', local_copy, 'fetch', '--quiet', '--depth=1', 'origin', commit })
    git({ '-C', local_copy, 'checkout', '--quiet', '--detach', 'FETCH_HEAD' })
  end
  return local_copy
end

-- A git hook runs with `GIT_DIR`, `GIT_INDEX_FILE` and the like pointing at
-- the repository being committed to. Left in place, a spec that runs git in a
-- scratch directory -- `git init` there -- acts on that repository instead.
for _, name in
  ipairs(vim.fn.systemlist({ 'git', 'rev-parse', '--local-env-vars' }))
do
  vim.env[name] = nil
end

-- The machine's git configuration reaches every repository a spec creates: an
-- `init.templatedir` copies its hooks into one, and the next commit there
-- runs them, under the `$PATH` the spec narrowed. Specs see git as CI does.
vim.env.GIT_CONFIG_GLOBAL = '/dev/null'
vim.env.GIT_CONFIG_NOSYSTEM = '1'

vim.opt.runtimepath = {
  root,
  dependency('plenary.nvim', 'https://github.com/nvim-lua/plenary.nvim'),
  dependency('lazy.nvim', 'https://github.com/folke/lazy.nvim'),
  vim.env.VIMRUNTIME,
}
vim.opt.packpath = {}
-- `config.globals` declares it; specs that stub one setting need the table
_G.DyNeo = {}
vim.opt.swapfile = false
vim.opt.shadafile = 'NONE'
-- What a module keeps between sessions -- the AI audit log among it -- goes
-- next to the tests, not into the state of the Neovim the specs run beside.
vim.env.XDG_STATE_HOME = vim.fs.joinpath(root, '.tests', 'state')

-- Neovim's own `ftplugin/lua.lua` and its like call `vim.treesitter.start`,
-- which throws on a machine with no parser for the filetype -- a fresh clone,
-- a container, CI. A spec that opens a file of that filetype would fail for
-- the machine it runs on rather than for what it is testing, and no spec here
-- is about Treesitter, so a missing parser makes the call a no-op.
local treesitter_start = vim.treesitter.start
vim.treesitter.start = function(...) pcall(treesitter_start, ...) end

-- Specs live outside `lua/`, so their shared helpers are found by path.
package.path = vim.fs.joinpath(root, 'tests', '?.lua') .. ';' .. package.path

vim.cmd.runtime({ 'plugin/plenary.vim', bang = true })
