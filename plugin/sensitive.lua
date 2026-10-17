-- Keep sensitive files out of the undo, swap and backup files. Installed at
-- startup rather than with `config.autocmds`, which `config.lazy` defers to
-- `VeryLazy`: `nvim -c 'e ~/.ssh/config'` would open the file before it.
local function augroup(name)
  return vim.api.nvim_create_augroup('dyneo_' .. name, { clear = true })
end

--- `path` with its symlinks resolved, as far up as it exists: a new file,
--- or one in a folder not made yet, keeps the part that is not there
---@param path string
---@return string
local function resolve(path)
  local rest = ''
  while true do
    local real = vim.uv.fs_realpath(path)
    if real then return (real:gsub('/$', '')) .. rest end
    local parent = vim.fs.dirname(path)
    if parent == path then return path .. rest end
    rest = '/' .. vim.fs.basename(path) .. rest
    path = parent
  end
end

-- Those files outlive it on disk in plain text. A file under the temporary
-- directory counts too, such as the decrypted copy `chezmoi edit` works on.
-- Both sides are resolved: on macOS `/tmp` and `$TMPDIR` are links into
-- `/private`, and a file reaches Neovim by either name.
local function leaves_no_copy(file)
  if file == '' then return false end
  file = vim.fs.normalize(vim.fn.fnamemodify(file, ':p'))
  local real = resolve(file)
  for _, tmp in ipairs({ vim.env.TMPDIR or '/tmp', '/tmp' }) do
    tmp = resolve(vim.fs.normalize(tmp))
    if tmp ~= '' and vim.startswith(real, tmp .. '/') then return true end
  end
  return require('util.sensitive').is_sensitive_path(file)
end

vim.api.nvim_create_autocmd({ 'BufReadPre', 'BufNewFile' }, {
  group = augroup('sensitive_no_copy'),
  callback = function(event)
    if not leaves_no_copy(event.match) then return end
    vim.bo[event.buf].undofile = false
    vim.bo[event.buf].swapfile = false
  end,
})

-- `backup` and `writebackup` are global: off for the one write only
local backup_saved
local restore_backup = function()
  if not backup_saved then return end
  vim.o.backup, vim.o.writebackup = backup_saved[1], backup_saved[2]
  backup_saved = nil
end
vim.api.nvim_create_autocmd(
  { 'BufWritePre', 'FileWritePre', 'FileAppendPre' },
  {
    group = augroup('sensitive_no_backup'),
    callback = function(event)
      if not leaves_no_copy(event.match) then return end
      -- Two writes before a restore, as when the first failed: keep what the
      -- first saved, not the values it forced off
      backup_saved = backup_saved or { vim.o.backup, vim.o.writebackup }
      vim.o.backup, vim.o.writebackup = false, false
      -- A failed write fires no `*WritePost`: the write is synchronous, so
      -- the next loop turn is after it either way
      vim.schedule(restore_backup)
    end,
  }
)
vim.api.nvim_create_autocmd(
  { 'BufWritePost', 'FileWritePost', 'FileAppendPost' },
  {
    group = augroup('sensitive_restore_backup'),
    callback = restore_backup,
  }
)
