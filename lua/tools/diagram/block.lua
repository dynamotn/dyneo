--- A preview of the diagram under the cursor -- a ```` ```mermaid ```` or
--- ```` ```d2 ```` block in Markdown, or a whole Mermaid file -- as a PNG
---
--- Mermaid is drawn by `mmdc`, D2 by `tools.diagram.d2.snacks`. The picture
--- opens where the D2 preview opens one under zellij: in a kitty overlay,
--- else the system viewer. zellij drops the kitty graphics protocol, so
--- `Snacks.image` cannot draw a block inline there. Renders are cached by
--- the text of the diagram. `ftplugin/markdown.lua` and
--- `ftplugin/mermaid.lua` map it.
local M = {}

M.CONFIG = {
  theme = 'dark',
  background = 'transparent',
  -- Device pixels a CSS pixel: 2 keeps text sharp in the overlay
  scale = 2,
}

--- Milliseconds `mmdc` may take: it starts a headless browser
M.TIMEOUT = 60 * 1000

--- The languages of a block this previews, and the overlay's title
M.LANGUAGES = { mermaid = 'Mermaid preview', d2 = 'D2 preview' }

local notify = require('util.notify').titled('Diagram')

--- Where Mermaid renders are kept, made on first use
---@return string
function M.cache_dir()
  local dir =
    vim.fn.resolve(vim.fn.stdpath('cache') .. '/diagram-cache/mermaid')
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- The body of the block of a language in `M.LANGUAGES` holding `row`,
--- fences included, and that language; nil when `row` is in no such block
---
--- Every fence is walked from the top, so a fence shown inside another
--- block, or a longer one, is not read as the end of it.
---@param lines string[]
---@param row integer 1-based
---@return string[]? body
---@return string? language
function M.block_at(lines, row)
  local open, fence, lang
  for i, line in ipairs(lines) do
    if not open then
      local marks, info = line:match('^%s*(```+)%s*(.-)%s*$')
      if not marks then
        marks, info = line:match('^%s*(~~~+)%s*(.-)%s*$')
      end
      if marks then
        open, fence, lang = i, marks, info:match('^[%w_-]*')
      end
    else
      local marks = line:match('^%s*([`~]+)%s*$')
      if
        marks
        and marks:sub(1, 1) == fence:sub(1, 1)
        and not marks:find(marks:sub(1, 1) == '`' and '~' or '`', 1, true)
        and #marks >= #fence
      then
        if row <= i then
          if row < open or not M.LANGUAGES[lang] then return nil end
          return vim.list_slice(lines, open + 1, i - 1), lang
        end
        open = nil
      end
    end
  end
  -- An unclosed block runs to the end of the text
  if open and row >= open and M.LANGUAGES[lang] then
    return vim.list_slice(lines, open + 1), lang
  end
end

--- Render the Mermaid `text` to a PNG and hand its path to `on_rendered`
---@param text string
---@param on_rendered fun(output_path: string)
local function render_mermaid(text, on_rendered)
  if vim.fn.executable('mmdc') == 0 then
    return notify(
      'mmdc not found in PATH: npm install -g @mermaid-js/mermaid-cli',
      vim.log.levels.ERROR
    )
  end
  local config = M.CONFIG
  local hash = vim.fn.sha256(
    table.concat({ config.theme, config.background, config.scale, text }, '\0')
  )
  local cache_dir = M.cache_dir()
  local input_path = cache_dir .. '/' .. hash .. '.mmd'
  local output_path = cache_dir .. '/' .. hash .. '.png'
  if vim.fn.filereadable(output_path) == 1 then
    return on_rendered(output_path)
  end

  vim.fn.writefile(vim.split(text, '\n'), input_path)
  local system = require('util.system')
  system.run({
    'mmdc',
    '-i',
    input_path,
    '-o',
    output_path,
    '-t',
    config.theme,
    '-b',
    config.background,
    '-s',
    tostring(config.scale),
  }, { timeout = M.TIMEOUT }, function(result)
    vim.uv.fs_unlink(input_path)
    if result.code ~= 0 then
      -- Never a half-written picture left in the cache
      vim.uv.fs_unlink(output_path)
      return notify(
        ('failed to render:\n%s'):format(system.failure(result, 'mmdc')),
        vim.log.levels.ERROR
      )
    end
    on_rendered(output_path)
  end)
end

--- Preview the diagram under the cursor of `bufnr`, the current buffer
--- unless given: the whole buffer when it is a Mermaid file
---@param bufnr? integer
function M.preview(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local lang = 'mermaid' ---@type string?
  if vim.bo[bufnr].filetype ~= 'mermaid' then
    local win = vim.fn.bufwinid(bufnr)
    local row = vim.api.nvim_win_get_cursor(win ~= -1 and win or 0)[1]
    lines, lang = M.block_at(lines, row)
    if not lines then
      return notify(
        'no mermaid or d2 block under the cursor',
        vim.log.levels.WARN
      )
    end
  end
  local d2 = require('tools.diagram.d2.snacks')
  local function show(output_path)
    d2.show_outside_zellij(output_path, M.LANGUAGES[lang])
  end
  local text = table.concat(lines, '\n')
  if lang == 'd2' then
    -- An unnamed buffer still renders: imports then resolve from the
    -- working directory
    local path = vim.api.nvim_buf_get_name(bufnr)
    d2.render(path ~= '' and path or vim.fn.getcwd() .. '/_', show, text)
  else
    render_mermaid(text, show)
  end
end

return M
