--- A copy of a file each time it is written, outside git
---
--- The undo file is dropped once the file changes behind the editor's back
--- (a checkout, a formatter, another editor); these copies are not. Each
--- write keeps one, when the content changed since the last, in a private
--- directory under `stdpath('state')`, the newest `M.LIMIT` per file.
--- `:DyLocalHistory` picks one and shows it against the buffer.
---
--- Nothing sensitive is copied (`util.sensitive`): a decrypted buffer or a
--- `.env` would otherwise leave its clear text on disk.
local M = {}

--- Copies kept per file
M.LIMIT = 50
--- A larger file is not copied
M.MAX_BYTES = 1024 * 1024

--- Where the copies are kept
---@return string
function M.dir() return vim.fn.stdpath('state') .. '/local-history' end

---@class DyLocalHistoryCopy
---@field file string
---@field seq integer
---@field time integer

--- The directory of the copies of `path`
---@param path string
---@return string
local function dir_of(path)
  return vim.fs.joinpath(M.dir(), vim.fn.sha256(path):sub(1, 16))
end

---@param path string
---@return string?
local function read(path)
  local f = io.open(path, 'rb')
  if not f then return nil end
  local data = f:read('*a')
  f:close()
  return data
end

--- The copies of `path`, newest first
---@param path string
---@return DyLocalHistoryCopy[]
function M.list(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local dir = dir_of(path)
  local copies = {}
  for name in vim.fs.dir(dir) do
    local seq, time = name:match('^(%d+)%-(%d+)$')
    if seq then
      table.insert(copies, {
        file = vim.fs.joinpath(dir, name),
        seq = tonumber(seq),
        time = tonumber(time),
      })
    end
  end
  table.sort(copies, function(a, b) return a.seq > b.seq end)
  return copies
end

--- Keep a copy of the file of `bufnr` as it is on disk, when it is one worth
--- keeping and it changed since the last copy
---@param bufnr integer
function M.save(bufnr)
  if vim.bo[bufnr].buftype ~= '' then return end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == '' or require('util.sensitive').is_sensitive(bufnr) then return end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' or stat.size > M.MAX_BYTES then return end
  local data = read(path)
  if not data then return end
  local copies = M.list(path)
  if copies[1] and read(copies[1].file) == data then return end

  local dir = dir_of(path)
  vim.fn.mkdir(dir, 'p', tonumber('700', 8))
  vim.fn.writefile({ path }, vim.fs.joinpath(dir, 'path'))
  local seq = (copies[1] and copies[1].seq or 0) + 1
  local file = vim.fs.joinpath(dir, ('%06d-%d'):format(seq, os.time()))
  local f = io.open(file, 'wb')
  if not f then return end
  f:write(data)
  f:close()
  vim.uv.fs_chmod(file, tonumber('600', 8))
  for i = M.LIMIT, #copies do
    vim.fn.delete(copies[i].file)
  end
end

--- Pick a copy of the current buffer's file and show it against the buffer
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local path = vim.api.nvim_buf_get_name(bufnr)
  local copies = path ~= '' and M.list(path) or {}
  if #copies == 0 then
    return vim.notify('No local history for this file', vim.log.levels.INFO)
  end
  vim.ui.select(copies, {
    prompt = 'Local history',
    format_item = function(copy)
      return os.date('%Y-%m-%d %H:%M:%S', copy.time) --[[@as string]]
    end,
  }, function(copy)
    if not copy then return end
    local filetype = vim.bo[bufnr].filetype
    vim.cmd('diffthis')
    vim.cmd('vertical new')
    local copy_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(
      copy_buf,
      0,
      -1,
      false,
      vim.fn.readfile(copy.file)
    )
    vim.bo[copy_buf].buftype = 'nofile'
    vim.bo[copy_buf].bufhidden = 'wipe'
    vim.bo[copy_buf].swapfile = false
    vim.bo[copy_buf].filetype = filetype
    vim.bo[copy_buf].modifiable = false
    vim.api.nvim_buf_set_name(
      copy_buf,
      ('local-history://%s@%d'):format(path, copy.seq)
    )
    vim.cmd('diffthis')
  end)
end

return M
