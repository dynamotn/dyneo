--- A file's bytes as a hex dump, edited and written back
---
--- `:DyHex` opens the bytes of the buffer's file, as they are on disk, in a
--- `dyhex://` buffer laid out the way `xxd` prints them, so the `xxd` syntax
--- colours it. `:w` there turns the hex columns back into bytes and writes
--- them over the file; the offsets are ignored, so a line deleted is its
--- bytes deleted. A line whose text column does not hold one character per
--- byte is refused rather than guessed at: it is a line joined, split or
--- edited in a way that would write the wrong bytes. Pure Lua: no `xxd`.
local M = {}

--- The most of a file opened. The dump is made and read back on the main
--- loop: about 0.3 s to open and 1.2 s to write at this size.
M.LIMIT = 4 * 1024 * 1024

local notify = require('util.notify').titled('Hex')

-- Each byte as its two hex digits, and back: `gsub` with a table is far
-- faster than with a function called per byte
local HEX, BYTE = {}, {}
for i = 0, 255 do
  local char, pair = string.char(i), ('%02x'):format(i)
  HEX[char] = pair
  for _, digits in ipairs({ pair, pair:upper() }) do
    BYTE[digits] = char
    BYTE[digits:sub(1, 1) .. pair:sub(2)] = char
    BYTE[pair:sub(1, 1) .. digits:sub(2)] = char
  end
end

-- The hex columns of 16 bytes, formatted in one call
local FULL_HEX = ('%02x%02x '):rep(8)

--- `bytes` as `xxd` prints them: offset, 16 bytes in pairs, the text
---@param bytes string
---@return string[]
function M.dump(bytes)
  local lines = {}
  local text = bytes:gsub('[^\32-\126]', '.')
  local full = #bytes - #bytes % 16
  for offset = 0, full - 1, 16 do
    lines[#lines + 1] = ('%08x: %s %s'):format(
      offset,
      FULL_HEX:format(bytes:byte(offset + 1, offset + 16)),
      text:sub(offset + 1, offset + 16)
    )
  end
  if full < #bytes then
    local hex = bytes:sub(full + 1):gsub('.', HEX):gsub('%x%x?%x?%x?', '%0 ')
    lines[#lines + 1] = ('%08x: %-40s %s'):format(full, hex, text:sub(full + 1))
  end
  return lines
end

--- The bytes of a dump. A line with an offset is read as `M.dump` lays it
--- out: hex groups up to the first two spaces, then a text column of one
--- character per byte, which ends the line. A line with no offset is bare
--- hex with no text column.
---@param lines string[]
---@return string? bytes
---@return string? err Which line could not be read
function M.parse(lines)
  local out = {}
  for number, line in ipairs(lines) do
    local _, colon = line:find('^%s*%x+:')
    local hex, text = colon and line:sub(colon + 1) or line, ''
    local gap = colon and hex:find('  ', 1, true)
    if gap then
      hex, text = hex:sub(1, gap - 1), hex:sub(gap + 2)
    end
    hex = hex:gsub('%s', '')
    -- Anything but hex pairs is left as it is, and so makes the bytes longer
    -- than half the digits
    local bytes = hex:gsub('%x%x', BYTE)
    if #bytes * 2 ~= #hex then
      return nil, ('line %d is not pairs of hex digits'):format(number)
    end
    -- The text column is the last characters, one per byte, after the
    -- padding: a byte shown as a space may start it
    if colon and (#text < #bytes or text:sub(1, #text - #bytes):find('%S')) then
      return nil,
        ('line %d has %d bytes and a text column of another length'):format(
          number,
          #bytes
        )
    end
    out[#out + 1] = bytes
  end
  return table.concat(out)
end

--- Why `path` cannot be dumped, if it cannot
---@param path string
---@return uv.fs_stat.result? stat
---@return string? err
local function check(path)
  -- A dump of a credential is the credential in clear text
  if require('util.sensitive').is_sensitive_path(path) then
    return nil, path .. ' is sensitive, not dumped'
  end
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.type ~= 'file' then
    return nil, path .. ' is not a file on disk'
  end
  if stat.size > M.LIMIT then
    return nil, ('%s is over %d MiB'):format(path, M.LIMIT / 1048576)
  end
  return stat
end

--- Size and modification time, to tell whether the file moved under a dump
---@param stat uv.fs_stat.result
---@return { size: integer, sec: integer, nsec: integer }
local function stamp(stat)
  return { size = stat.size, sec = stat.mtime.sec, nsec = stat.mtime.nsec }
end

local group = vim.api.nvim_create_augroup('dy_hex', { clear = false })

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
  local _, err = check(path)
  if err then return notify(err, vim.log.levels.WARN) end
  -- Sixteen bytes a line, a credential is split where no pattern finds it
  local sensitive = require('util.sensitive')
  if sensitive.is_sensitive(0) then
    return notify(
      'Not dumped: ' .. table.concat(sensitive.reasons(0), '; '),
      vim.log.levels.WARN
    )
  end
  -- `:edit` finds a dump already open by its whole name, and reads a new
  -- one through the `BufReadCmd` of `plugin/hex.lua`
  vim.cmd.edit(vim.fn.fnameescape('dyhex://' .. path))
end

--- Fill the `dyhex://` buffer `bufnr` with the dump of its file: on
--- `:DyHex`, `:e!` and a session restored
---@param bufnr integer
function M.read(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr):gsub('^dyhex://', '')
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  -- Until the file is read, the buffer is no dump and `:w` writes nothing
  vim.b[bufnr].dyhex = nil
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_clear_autocmds({ group = group, buffer = bufnr })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    group = group,
    buffer = bufnr,
    callback = function(args) M.write(bufnr, args.match) end,
  })
  -- `:1,3w` and `:w >> file` write part of the dump
  vim.api.nvim_create_autocmd({ 'FileWriteCmd', 'FileAppendCmd' }, {
    group = group,
    buffer = bufnr,
    callback = function()
      notify(
        'Only the whole dump is written, nothing written',
        vim.log.levels.ERROR
      )
    end,
  })

  local stat, err = check(path)
  local file, open_err
  if stat then
    file, open_err = io.open(path, 'rb')
    err = open_err
  end
  if not file then return notify(err, vim.log.levels.ERROR) end
  local bytes = file:read('*a')
  file:close()
  -- Opened without `:DyHex` (a session, `:e dyhex://...`): the file's text
  -- is looked at here, since the dump hides it from every later check
  local sensitive = require('util.sensitive')
  for line in bytes:gmatch('[^\n]+') do
    local rule = sensitive.secret_format(line)
    if rule then
      sensitive.mark(bufnr, ('hex dump of a file holding a %s'):format(rule))
      break
    end
  end

  -- Loading the dump is no edit: undoing it would empty the buffer, and a
  -- `:w` then empty the file
  local levels = vim.bo[bufnr].undolevels
  vim.bo[bufnr].undolevels = -1
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.dump(bytes))
  vim.bo[bufnr].undolevels = levels
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = 'xxd'
  vim.b[bufnr].dyhex = { path = path, stamp = stamp(stat) }
end

--- Write the bytes of the dump in `bufnr` over its file, when `target` is
--- the dump itself
---@param bufnr integer
---@param target string The file name the write is for (`<amatch>`)
function M.write(bufnr, target)
  local state = vim.b[bufnr].dyhex
  local function refuse(msg)
    notify(msg .. ', nothing written', vim.log.levels.ERROR)
  end
  if not state then return refuse('The dump was not read from its file') end
  local name = 'dyhex://' .. state.path
  -- `:w other` and `:saveas` are no way to write the dump's bytes elsewhere
  if target ~= name or vim.api.nvim_buf_get_name(bufnr) ~= name then
    return refuse('A dump is written only over its own file, with `:w`')
  end
  local stat = vim.uv.fs_stat(state.path)
  if not stat or not vim.deep_equal(stamp(stat), state.stamp) then
    return refuse(state.path .. ' changed on disk, `:e!` dumps it again')
  end
  local bytes, err = M.parse(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  if not bytes then return refuse(err) end

  local file, open_err = io.open(state.path, 'wb')
  if not file then return refuse(open_err) end
  local written, write_err = file:write(bytes)
  local closed, close_err = file:close()
  if not written or not closed then
    return notify(
      ('%s may be cut short: %s'):format(state.path, write_err or close_err),
      vim.log.levels.ERROR
    )
  end
  stat = vim.uv.fs_stat(state.path)
  vim.b[bufnr].dyhex =
    { path = state.path, stamp = stat and stamp(stat) or state.stamp }
  vim.bo[bufnr].modified = false
  notify(('%d bytes written to %s'):format(#bytes, state.path))
  -- The file's own buffer, if open, sees the change on its next check
  vim.cmd.checktime()
end

return M
