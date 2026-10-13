--- A weighted decision matrix, kept as a Markdown table
---
--- A row per criterion, its weight in the second column and a score for
--- each option after it; a last `**Total**` row holds the sum of weight
--- times score of each option, the best one in bold. `:DyMatrix` works the
--- totals out again for the table under the cursor, and lines its columns
--- up; outside a table it writes one to fill in -- in a decision record,
--- as its `## Options` section, just before `## Decision`.
local M = {}

local notify = require('util.notify').titled('Matrix')

--- The table written when there is none
M.TEMPLATE = {
  '| Criterion | Weight | Option A | Option B |',
  '| --- | --: | --: | --: |',
  '| Cost | 3 | 3 | 4 |',
  '| Operability | 2 | 4 | 2 |',
  '| Fit with the team | 1 | 5 | 3 |',
  '| **Total** | | | |',
}

---@class DyMatrix
---@field header string[] The cells of the first row
---@field rows string[][] The criteria, their cells as written
---@field totals number[] Per option
---@field ignored string[] `line: cell` of the cells read as nought though
---not empty

--- The cells of a table row: `| a | b |` -> `{ 'a', 'b' }`
---@param line string
---@return string[]
local function cells(line)
  local inner = vim.trim(line):gsub('^|', ''):gsub('|$', '')
  -- shortcut: an escaped `\|` inside a cell splits it, quote it when one is needed
  return vim.tbl_map(vim.trim, vim.split(inner, '|', { plain = true }))
end

--- Whether `cell` names the total row
---@param cell string
---@return boolean
local function is_total(cell) return cell:gsub('%*', ''):lower() == 'total' end

--- The first and last line (1-based) of the table around `row`, or nil
---@param lines string[]
---@param row integer
---@return integer? first
---@return integer? last
function M.bounds(lines, row)
  if not (lines[row] or ''):match('^%s*|') then return nil end
  local first, last = row, row
  while first > 1 and lines[first - 1]:match('^%s*|') do
    first = first - 1
  end
  while last < #lines and lines[last + 1]:match('^%s*|') do
    last = last + 1
  end
  return first, last
end

--- `cell` as a number, its emphasis (`**5**`) aside; nil when it is none
---@param cell string
---@return number?
local function score(cell)
  return tonumber((cell:gsub('^[*_]+', ''):gsub('[*_]+$', '')))
end

--- `lines`, a whole table, read as a matrix; nil with why when it is none
---@param lines string[]
---@param first? integer The line number of `lines[1]`, for messages
---@return DyMatrix? matrix
---@return string? err
function M.parse(lines, first)
  first = first or 1
  local header = cells(lines[1] or '')
  if #header < 3 or header[2]:lower() ~= 'weight' then
    return nil, 'Not a decision matrix: its second column is not `Weight`'
  end
  local matrix = { header = header, rows = {}, totals = {}, ignored = {} }
  for i = 3, #header do
    matrix.totals[i - 2] = 0
  end
  local wide = {}
  for index = 3, #lines do
    local row = cells(lines[index])
    local lnum = first + index - 1
    -- Refused rather than cut: rewriting the table would drop the extra cells
    if #row > #header then table.insert(wide, lnum) end
    if not is_total(row[1] or '') then
      for i = 2, #row do
        if row[i] ~= '' and not score(row[i]) then
          table.insert(matrix.ignored, ('%d: `%s`'):format(lnum, row[i]))
        end
      end
      local weight = score(row[2] or '') or 0
      for i = 3, #header do
        matrix.totals[i - 2] = matrix.totals[i - 2]
          + weight * (score(row[i] or '') or 0)
      end
      table.insert(matrix.rows, row)
    end
  end
  if #wide > 0 then
    return nil,
      ('More cells than the header has columns, line %s'):format(
        table.concat(wide, ', ')
      )
  end
  return matrix
end

--- A number without a trailing `.0`, and never in exponent form
---@param n number
---@return string
local function number(n)
  return (('%.6f'):format(n):gsub('0+$', ''):gsub('%.$', ''))
end

--- `matrix` as the lines of a table, its columns lined up
---@param matrix DyMatrix
---@return string[]
function M.render(matrix)
  local best = math.max(unpack(matrix.totals))
  local total = { '**Total**', '' }
  for _, sum in ipairs(matrix.totals) do
    table.insert(
      total,
      sum == best and ('**%s**'):format(number(sum)) or number(sum)
    )
  end
  local rows = { matrix.header }
  vim.list_extend(rows, matrix.rows)
  table.insert(rows, total)
  local widths = {}
  for i = 1, #matrix.header do
    widths[i] = 3
    for _, row in ipairs(rows) do
      widths[i] = math.max(widths[i], vim.api.nvim_strwidth(row[i] or ''))
    end
  end
  local function line(row, rule)
    local out = {}
    for i, width in ipairs(widths) do
      local cell = row and (row[i] or '')
        or (i == 1 and ('-'):rep(width) or ('-'):rep(width - 1) .. ':')
      local pad = (' '):rep(width - vim.api.nvim_strwidth(cell))
      table.insert(out, (i == 1 or rule) and cell .. pad or pad .. cell)
    end
    return '| ' .. table.concat(out, ' | ') .. ' |'
  end
  local out = { line(matrix.header, true), line(nil, true) }
  for i = 2, #rows do
    table.insert(out, line(rows[i]))
  end
  return out
end

--- Where a new table goes in `lines`: before `## Decision` of a decision
--- record, with a heading of its own, else after `row`
---@param lines string[]
---@param row integer
---@return integer at 0-based line to insert at
---@return string[] lines
function M.placement(lines, row)
  local is_record = (lines[1] or ''):match('^#%s+%d+%.%s')
  for index, text in ipairs(lines) do
    if is_record and text:match('^##%s+Decision%s*$') then
      local block = { '## Options', '' }
      vim.list_extend(block, M.TEMPLATE)
      table.insert(block, '')
      return index - 1, block
    end
  end
  return row, M.TEMPLATE
end

--- Work out the table under the cursor again, or write a new one
function M.update()
  local bufnr = vim.api.nvim_get_current_buf()
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first, last = M.bounds(lines, row)
  if not first then
    local at, block = M.placement(lines, row)
    vim.api.nvim_buf_set_lines(bufnr, at, at, false, block)
    local start = at + #block - #M.TEMPLATE
    if block ~= M.TEMPLATE then start = start - 1 end
    first, last = start + 1, start + #M.TEMPLATE
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  end
  local matrix, err = M.parse(vim.list_slice(lines, first, last), first)
  if not matrix then return notify(err, vim.log.levels.WARN) end
  vim.api.nvim_buf_set_lines(bufnr, first - 1, last, false, M.render(matrix))
  if #matrix.ignored > 0 then
    notify(
      'Not numbers, counted as nought, at line\n'
        .. table.concat(matrix.ignored, '\n'),
      vim.log.levels.WARN
    )
  end
end

return M
