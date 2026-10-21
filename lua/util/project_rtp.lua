--- The project's own `.nvim` folder on the runtimepath
---
--- Whatever sits in its `plugin/` runs on its own, and that is code belonging
--- to whichever repository happens to be open. So it passes through the same
--- trust database as `exrc`: the folder is added once it has been trusted, and
--- Neovim asks otherwise. `:trust` takes the decision back. Trust on a
--- directory goes by name rather than contents, so it also covers files put
--- there later.

local M = {}

---@type string? Folder currently on the runtimepath
local project_rtp
---@type table<string, boolean> Verdict per folder, kept for the session so
--- that walking back into a project neither asks again nor loses its folder
local trusted_rtp = {}
---@type number? When the trust database last changed, as `trusted_rtp` knows it
local trust_mtime

---@param directory string
---@return boolean
local function is_trusted(directory)
  -- `:trust` changes its database: a verdict taken back there must not live
  -- on here until the next session
  local stat = vim.uv.fs_stat(vim.fn.stdpath('state') .. '/trust')
  local mtime = stat and (stat.mtime.sec * 1e9 + stat.mtime.nsec) or 0
  if mtime ~= trust_mtime then
    trust_mtime = mtime
    trusted_rtp = {}
  end
  if trusted_rtp[directory] == nil then
    -- `vim.secure.read` blocks on its prompt and goes on handling events while
    -- it waits, so the verdict is pinned before the question is put: without
    -- it a second pass arrives mid-prompt, finds nothing recorded yet, and
    -- asks about the same folder all over again.
    trusted_rtp[directory] = false
    trusted_rtp[directory] = vim.fn.isdirectory(directory) == 1
      and vim.secure.read(directory) ~= nil
  end
  return trusted_rtp[directory]
end

local function setup_project_rtp()
  local root = require('util.root').get()
  local directory = root .. '/.nvim'
  -- Asked before the folder already on the runtimepath is kept: `:trust`
  -- may have taken it back. A held root (a review's worktree) is not even
  -- asked about, and its verdict is not kept, so it is asked about as usual
  -- once let go.
  local trusted = not require('util.untrusted').held(root)
    and is_trusted(directory)
  if directory == project_rtp and trusted then return end
  if project_rtp then
    vim.opt.rtp:remove(project_rtp)
    project_rtp = nil
  end
  if trusted then
    vim.opt.rtp:append(directory)
    project_rtp = directory
  end
end

--- The folder to start with, if it is trusted, for lazy.nvim to keep on the
--- runtimepath it resets: it then sources the folder's `plugin/` along with
--- every other path's
---@return string?
function M.startup_path()
  setup_project_rtp()
  return project_rtp
end

--- The project's `.nvim` folder while it is trusted and on the runtimepath
---@return string?
function M.current() return project_rtp end

--- Follow the root as the working directory moves. Called once lazy.nvim has
--- set up, after it has reset the runtimepath.
function M.setup()
  if not project_rtp then
    setup_project_rtp()
  elseif not vim.list_contains(vim.opt.rtp:get(), project_rtp) then
    vim.opt.rtp:append(project_rtp)
  end
  -- The root follows the working directory, so it is worth another look
  -- whenever that moves, instead of being settled once at startup.
  -- `util.root` drops its cached root from a handler of this very event, so
  -- the fresh one is only there once the event has been dealt with.
  vim.api.nvim_create_autocmd('DirChanged', {
    group = vim.api.nvim_create_augroup('dy_project_rtp', { clear = true }),
    callback = function() vim.schedule(setup_project_rtp) end,
  })
  -- A held root is let go without the directory moving: the look it was
  -- denied is taken then, once for all of its buffers
  local pending = false
  require('util.untrusted').on_release('project_rtp', function()
    if pending then return end
    pending = true
    vim.schedule(function()
      pending = false
      setup_project_rtp()
    end)
  end)
end

return M
