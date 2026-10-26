--- A preview of the d2 diagram of a buffer, as a PNG shown by `Snacks.image`
---
--- d2 draws an SVG, an SVG converter makes the PNG, and the PNG opens in a
--- split -- or, under zellij, which drops the kitty graphics protocol, in a
--- kitty overlay or the system viewer. Renders are cached by the contents of
--- the diagram and of every file it imports. `ftplugin/d2.lua` maps it.
local M = {}

M.CONFIG = {
  theme_id = 4,
  dark_theme_id = 4,
  layout = 'tala',
  -- Longest side of the preview, in pixels, when Quick Look rasterizes it
  max_size = 4096,
}

--- Milliseconds d2 may take: a `tala` layout of a large diagram is slow
M.TIMEOUT = 2 * 60 * 1000

--- Milliseconds a converter or the kitty overlay may take
M.CONVERT_TIMEOUT = 60 * 1000

--- Most files followed through imports for the cache key
M.MAX_IMPORTS = 200

local preview_buf = nil
local preview_win = nil

local notify = require('util.notify').titled('D2')

--- Where renders are kept, made on first use
---@return string
function M.cache_dir()
  local dir = vim.fn.resolve(vim.fn.stdpath('cache') .. '/diagram-cache/d2')
  vim.fn.mkdir(dir, 'p')
  return dir
end

--- Throw away renders more than a week old
---
--- The cache key follows the contents of a diagram, so every edit leaves the
--- previous render behind. Age is the only test: a render still in use is
--- dropped as well, and simply drawn again.
local function prune_cache()
  local week = 7 * 24 * 60 * 60
  local now = os.time()
  for _, file in ipairs(vim.fn.glob(M.cache_dir() .. '/*.png', true, true)) do
    local stat = vim.uv.fs_stat(file)
    if stat and now - stat.mtime.sec > week then vim.uv.fs_unlink(file) end
  end
end

--- The files `text`, the diagram at `path`, imports: `x: @file` and
--- `...@file`, relative to its directory, `.d2` added when left out
---@param path string
---@param text string
---@return string[]
function M.imports(path, text)
  local dir = vim.fs.dirname(path)
  local found, seen = {}, {}
  for _, pattern in ipairs({ ':%s*@([^%s;{}]+)', '%.%.%.@([^%s;{}]+)' }) do
    for name in text:gmatch(pattern) do
      name = name:gsub('^"(.*)"$', '%1')
      if not name:match('%.d2$') then name = name .. '.d2' end
      local file = vim.fs.normalize(
        name:sub(1, 1) == '/' and name or vim.fs.joinpath(dir, name)
      )
      if not seen[file] then
        seen[file] = true
        table.insert(found, file)
      end
    end
  end
  return found
end

--- The cache key of the diagram at `path`: its text and that of every file
--- it imports, followed as far as they import, up to `M.MAX_IMPORTS`
---@param path string
---@param text string
---@return string
function M.content_hash(path, text)
  local parts = { text }
  local seen = { [vim.fn.resolve(path)] = true }
  local queue = M.imports(path, text)
  local index = 0
  while index < #queue and index < M.MAX_IMPORTS do
    index = index + 1
    local file = queue[index]
    local real = vim.fn.resolve(file)
    if not seen[real] then
      seen[real] = true
      local ok, lines = pcall(vim.fn.readfile, file)
      if ok then
        local imported = table.concat(lines, '\n')
        table.insert(parts, file .. '\0' .. imported)
        vim.list_extend(queue, M.imports(file, imported))
      end
    end
  end
  return vim.fn.sha256(table.concat(parts, '\0'))
end

--- Run `command`, then `next_step`; `on_fail` hears why it did not work
---@param command string[]
---@param next_step fun()
---@param on_fail fun(err: string)
local function step(command, next_step, on_fail)
  local system = require('util.system')
  system.run(command, { timeout = M.CONVERT_TIMEOUT }, function(result)
    if result.code ~= 0 then
      return on_fail(system.failure(result, table.concat(command, ' ')))
    end
    next_step()
  end)
end

--- Turn the SVG at `svg_path` into the PNG at `png_path`
---
--- d2 can write a PNG itself, but its rasterizer turns down icons over 64 KiB
--- and SVG attributes such as `enable-background`, which several of the
--- icons.terrastruct.com icons carry. Its SVG output takes them all.
---@param svg_path string
---@param png_path string
---@param on_done fun(err?: string)
local function svg_to_png(svg_path, png_path, on_done)
  local function done() on_done() end
  if vim.fn.executable('rsvg-convert') == 1 then
    step({ 'rsvg-convert', '-o', png_path, svg_path }, done, on_done)
  elseif vim.fn.executable('resvg') == 1 then
    step({ 'resvg', svg_path, png_path }, done, on_done)
  elseif vim.fn.executable('magick') == 1 then
    step({ 'magick', '-background', 'none', svg_path, png_path }, done, on_done)
  elseif vim.fn.executable('qlmanage') == 1 then
    -- Quick Look draws the SVG with WebKit, so fonts and icons come out right,
    -- but always on a square canvas with the picture at the top left
    local width, height = 1, 1
    local head = table.concat(vim.fn.readfile(svg_path, '', 5), '\n')
    local w, h = head:match('viewBox="[-%d.]+ [-%d.]+ ([%d.]+) ([%d.]+)"')
    if w then
      width, height = tonumber(w), tonumber(h)
    end
    local size = M.CONFIG.max_size
    local out_dir = vim.fn.fnamemodify(png_path, ':h')
    local thumbnail = out_dir
      .. '/'
      .. vim.fn.fnamemodify(svg_path, ':t')
      .. '.png'
    local crop_width = math.floor(size * math.min(1, width / height))
    local crop_height = math.floor(size * math.min(1, height / width))

    step(
      { 'qlmanage', '-t', '-s', tostring(size), '-o', out_dir, svg_path },
      function()
        -- `sips` reads an offset of 0 as no offset at all and crops around
        -- the centre, so start one pixel in
        step({
          'sips',
          '--cropOffset',
          '1',
          '1',
          '-c',
          tostring(crop_height),
          tostring(crop_width),
          thumbnail,
          '--out',
          png_path,
        }, function()
          vim.uv.fs_unlink(thumbnail)
          on_done()
        end, function(err)
          vim.uv.fs_unlink(thumbnail)
          on_done(err)
        end)
      end,
      on_done
    )
  else
    on_done('no SVG converter found: install rsvg-convert, resvg or magick')
  end
end

--- Render `source_path` to a PNG and hand the path to `on_rendered`
---
--- With `text`, that is the diagram, read by d2 from stdin: a block of a
--- Markdown file at `source_path`, whose imports resolve from its directory.
---@param source_path string
---@param on_rendered fun(output_path: string)
---@param text? string
function M.render(source_path, on_rendered, text)
  if vim.fn.executable('d2') == 0 then
    return notify('d2 not found in PATH', vim.log.levels.ERROR)
  end
  local stdin = text ~= nil
  if not text then
    local ok, lines = pcall(vim.fn.readfile, source_path)
    if not ok then return end
    text = table.concat(lines, '\n')
  end

  -- Keyed on the contents rather than the timestamp, which two edits within
  -- the same second share
  local hash = M.content_hash(source_path, text)
  local cache_dir = M.cache_dir()
  local svg_path = vim.fn.resolve(cache_dir .. '/' .. hash .. '.svg')
  local output_path = vim.fn.resolve(cache_dir .. '/' .. hash .. '.png')

  if vim.fn.filereadable(output_path) == 1 then
    return on_rendered(output_path)
  end

  local command = {
    'd2',
    stdin and '-' or source_path,
    svg_path,
    '-t',
    tostring(M.CONFIG.theme_id),
    '--dark-theme',
    tostring(M.CONFIG.dark_theme_id),
  }
  -- The flag wins over `vars.d2-config.layout-engine`, so it would silently
  -- replace the layout the diagram asks for
  if not text:find('layout%-engine%s*:') then
    vim.list_extend(command, { '--layout', M.CONFIG.layout })
  end

  local function fail(message)
    -- Never a half-written SVG left in the cache
    vim.uv.fs_unlink(svg_path)
    notify(
      ('failed to render:\n%s'):format(message or ''),
      vim.log.levels.ERROR
    )
  end

  -- Off the main loop: a `tala` layout takes its time
  local system = require('util.system')
  system.run(command, {
    timeout = M.TIMEOUT,
    cwd = vim.fs.dirname(source_path),
    stdin = stdin and text or nil,
  }, function(result)
    if result.code ~= 0 then return fail(system.failure(result, 'd2')) end
    svg_to_png(svg_path, output_path, function(err)
      vim.uv.fs_unlink(svg_path)
      if err then return fail(err) end
      prune_cache()
      on_rendered(output_path)
    end)
  end)
end

--- Show `output_path` outside of zellij, which drops the kitty graphics
--- protocol, so snacks.nvim has nothing to draw into
---
--- Kitty's remote control opens the picture in an overlay above the zellij
--- window; without it, the system viewer takes over. The Mermaid preview
--- shows its pictures here too.
---@param output_path string
---@param title? string The overlay's title, `D2 preview` unless given
function M.show_outside_zellij(output_path, title)
  local listen_on = vim.env.KITTY_LISTEN_ON
  if not listen_on or vim.fn.executable('kitten') == 0 then
    vim.ui.open(output_path)
    return
  end

  local system = require('util.system')
  system.run({
    'kitten',
    '@',
    '--to',
    listen_on,
    'launch',
    '--type=overlay',
    '--title=' .. (title or 'D2 preview'),
    'kitten',
    'icat',
    '--hold',
    output_path,
  }, { timeout = M.CONVERT_TIMEOUT }, function(result)
    if result.code == 0 then return end
    notify(
      ('kitty overlay failed, opening externally:\n%s'):format(
        system.failure(result, 'kitten')
      ),
      vim.log.levels.WARN
    )
    vim.ui.open(output_path)
  end)
end

--- Preview the diagram of `bufnr`, the current buffer unless given
---@param bufnr? integer
function M.preview(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local source_path = vim.api.nvim_buf_get_name(bufnr)
  if not source_path or source_path == '' then return end

  -- The window to come back to, since the render does not block and the
  -- cursor may have moved on by the time it lands
  local source_win = vim.api.nvim_get_current_win()

  M.render(source_path, function(output_path)
    if vim.env.ZELLIJ ~= nil then
      M.show_outside_zellij(output_path)
      return
    end

    -- Close previous preview
    if preview_win and vim.api.nvim_win_is_valid(preview_win) then
      vim.api.nvim_win_close(preview_win, true)
    end
    if preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
      vim.api.nvim_buf_delete(preview_buf, { force = true })
    end

    if not vim.api.nvim_win_is_valid(source_win) then return end
    vim.api.nvim_set_current_win(source_win)

    -- Open image in a new split
    vim.cmd('vsplit ' .. vim.fn.fnameescape(output_path))
    preview_win = vim.api.nvim_get_current_win()
    preview_buf = vim.api.nvim_get_current_buf()
  end)
end

return M
