--- Code cells: the `# %%` blocks of a script, as Jupytext, VS Code and
--- Spyder write them
---
--- A cell runs from its marker down to the line before the next one; the
--- lines above the first marker are a cell too. iron.nvim sends a cell by
--- the same markers (`block_dividers`), so what `ij` selects is what
--- `<localleader>c` sends.
local M = {}

--- A line that starts a cell: `# %%`, `#%%`, or `# %% [markdown]` -- the
--- `block_dividers` iron.nvim is given, which it matches at the start of a
--- line
M.MARKER = '^# ?%%%%'

--- First and last line (1-based) of the cell holding `line`
---@param bufnr integer
---@param line integer
---@return integer first The marker, or 1 above the first marker
---@return integer last
function M.range(bufnr, line)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local first = 1
  for number = math.min(line, #lines), 1, -1 do
    if lines[number]:match(M.MARKER) then
      first = number
      break
    end
  end
  local last = #lines
  for number = math.max(line, first) + 1, #lines do
    if lines[number]:match(M.MARKER) then
      last = number - 1
      break
    end
  end
  return first, last
end

--- Move the cursor to the marker of the next cell, or of the previous one
---@param backward? boolean
function M.jump(backward)
  local pattern = [[^# \=%%]]
  for _ = 1, vim.v.count1 do
    if vim.fn.search(pattern, backward and 'bW' or 'W') == 0 then break end
  end
end

--- The cell under the cursor as a mini.ai region: `aj` with its marker,
--- `ij` without it and without the blank lines that close it
---@param ai_type 'a'|'i'
---@return table?
function M.textobject(ai_type)
  local first, last = M.range(0, vim.fn.line('.'))
  if ai_type == 'i' then
    if vim.fn.getline(first):match(M.MARKER) then first = first + 1 end
    while last >= first and vim.trim(vim.fn.getline(last)) == '' do
      last = last - 1
    end
  end
  if last < first then return nil end
  return {
    from = { line = first, col = 1 },
    to = { line = last, col = math.max(#vim.fn.getline(last), 1) },
    -- Whole lines: `dij` leaves no empty line behind
    vis_mode = 'V',
  }
end

return M
