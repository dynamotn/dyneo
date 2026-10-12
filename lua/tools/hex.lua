--- A file's bytes as a hex dump, edited and written back
---
--- `:DyHex` opens the bytes of the buffer's file, as they are on disk, in a
--- buffer of their own laid out the way `xxd` prints them, so the `xxd`
--- syntax colours it. `:w` there turns the hex columns back into bytes and
--- writes them over the file; the offsets and the text column are ignored,
--- so a line deleted is its bytes deleted. Pure Lua: no `xxd` needed.
local M = {}

--- The most of a file opened; a dump is about four times the file
M.LIMIT = 16 * 1024 * 1024

local notify = require('util.notify').titled('Hex')

--- `bytes` as `xxd` prints them: offset, 16 bytes in pairs, the text
---@param bytes string
---@return string[]
function M.dump(bytes)
  local lines = {}
  for offset = 0, #bytes - 1, 16 do
    local chunk = bytes:sub(offset + 1, offset + 16)
    local hex = chunk:gsub('..?', function(pair)
      return (pair:gsub('.', function(c) return ('%02x'):format(c:byte()) end))
        .. ' '
    end)
    local text = chunk:gsub('[^\32-\126]', '.')
    table.insert(lines, ('%08x: %-40s %s'):format(offset, hex, text))
  end
  return lines
end

--- The bytes of a dump: the hex columns of each line, up to the two spaces
--- before the text column
---@param lines string[]
---@return string? bytes
---@return string? err Which line could not be read
function M.parse(lines)
  local out = {}
  for number, line in ipairs(lines) do
    local columns = line:gsub('^%s*%x+:', '', 1)
    local hex = (columns:match('^%s*(.-)%s%s') or columns):gsub('%s', '')
    if hex:find('%X') or #hex % 2 == 1 then
      return nil, ('line %d is not pairs of hex digits'):format(number)
    end
    table.insert(
      out,
      (
        hex:gsub(
          '%x%x',
          function(pair) return string.char(tonumber(pair, 16)) end
        )
      )
    )
  end
  return table.concat(out)
end

local group = vim.api.nvim_create_augroup('dy_hex', { clear = true })

--- Open the hex dump of the current buffer's file
function M.open()
  local path = vim.api.nvim_buf_get_name(0)
  if path == '' or vim.bo.buftype ~= '' then
    return notify('The buffer has no file', vim.log.levels.WARN)
  end
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  -- The dump would show the bytes on disk, not the edits
  if vim.bo.modified then
    return notify('Write the buffer first', vim.log.levels.WARN)
  end
  -- A dump of a credential is the credential in clear text
  if require('util.sensitive').is_sensitive_path(path) then
    return notify(path .. ' is sensitive, not dumped', vim.log.levels.WARN)
  end
  local name = 'dyhex://' .. path
  local existing = vim.fn.bufnr(name)
  if existing ~= -1 then return vim.cmd.buffer(existing) end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return notify(path .. ' is not a file on disk', vim.log.levels.WARN)
  end
  if stat.size > M.LIMIT then
    return notify(
      ('%s is over %d MiB'):format(path, M.LIMIT / 1048576),
      vim.log.levels.ERROR
    )
  end
  local file = assert(io.open(path, 'rb'))
  local bytes = file:read('*a')
  file:close()

  local bufnr = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(bufnr, name)
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.dump(bytes))
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = 'xxd'
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    callback = function() M.write(bufnr, path) end,
  })
  vim.api.nvim_set_current_buf(bufnr)
end

--- Write the bytes of the dump in `bufnr` over `path`
---@param bufnr integer
---@param path string
function M.write(bufnr, path)
  local bytes, err = M.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if not bytes then
    return notify(err .. ', nothing written', vim.log.levels.ERROR)
  end
  local file, open_err = io.open(path, 'wb')
  if not file then return notify(open_err, vim.log.levels.ERROR) end
  file:write(bytes)
  file:close()
  vim.bo[bufnr].modified = false
  notify(('%d bytes written to %s'):format(#bytes, path))
  -- The file's own buffer, if open, sees the change on its next check
  vim.cmd.checktime()
end

return M
