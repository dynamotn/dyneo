--- Lualine components shared by the specs adding to the status line
---@class util.lualine
local M = {}

--- The length of `dir` and its separator when `path` lies under it: `/x/proj`
--- holds `/x/proj/a.lua`, not `/x/proj-other/a.lua`
---@param dir string
---@param path string
---@return integer?
local function under(dir, path)
  local prefix = dir:sub(-1) == '/' and dir or dir .. '/'
  if path:sub(1, #prefix) == prefix then return #prefix end
end

--- An icon coloured by what `status` reports, hidden while it reports nil
---@param icon string
---@param status fun(): nil|'ok'|'error'|'pending'
function M.status(icon, status)
  local colors = {
    ok = 'Special',
    error = 'DiagnosticError',
    pending = 'DiagnosticWarn',
  }
  return {
    function() return icon end,
    cond = function() return status() ~= nil end,
    color = function()
      return { fg = Snacks.util.color(colors[status()] or colors.ok) }
    end,
  }
end

--- `text` in the colours of `hl_group`, on the component's own background
---@param component any
---@param text string
---@param hl_group? string
---@return string
function M.format(component, text, hl_group)
  text = text:gsub('%%', '%%%%')
  if not hl_group or hl_group == '' then return text end
  ---@type table<string, string>
  component.hl_cache = component.hl_cache or {}
  local lualine_hl_group = component.hl_cache[hl_group]
  if not lualine_hl_group then
    local utils = require('lualine.utils.utils')
    ---@type string[]
    local gui = vim.tbl_filter(function(x) return x end, {
      utils.extract_highlight_colors(hl_group, 'bold') and 'bold',
      utils.extract_highlight_colors(hl_group, 'italic') and 'italic',
    })

    lualine_hl_group = component:create_hl({
      fg = utils.extract_highlight_colors(hl_group, 'fg'),
      gui = #gui > 0 and table.concat(gui, ',') or nil,
    }, 'DyNeo_' .. hl_group) --[[@as string]]
    component.hl_cache[hl_group] = lualine_hl_group
  end
  return component:format_hl(lualine_hl_group)
    .. text
    .. component:get_default_hl()
end

--- Path of the buffer, relative to the cwd or the root, cut to its last
--- `length` parts
---@param opts? {relative: 'cwd'|'root', modified_hl: string?, directory_hl: string?, filename_hl: string?, modified_sign: string?, readonly_icon: string?, length: number?}
function M.pretty_path(opts)
  opts = vim.tbl_extend('force', {
    relative = 'cwd',
    modified_hl = 'MatchParen',
    directory_hl = '',
    filename_hl = 'Bold',
    modified_sign = '',
    readonly_icon = ' 󰌾 ',
    length = 3,
  }, opts or {})

  return function(self)
    local path = vim.fn.expand('%:p') --[[@as string]]

    if path == '' then return '' end

    local Root = require('util.root')
    path = require('util.plugin').norm(path)
    local root = Root.get({ normalize = true })
    local cwd = Root.cwd()

    -- Compare on a lowered copy on Windows, and show the path as it was
    local norm_path = path

    if vim.fn.has('win32') == 1 then
      norm_path = norm_path:lower()
      root = root:lower()
      cwd = cwd:lower()
    end

    local skip = opts.relative == 'cwd' and under(cwd, norm_path)
      or under(root, norm_path)
    if not skip then
      -- A symlink into the project (chezmoi's `mode: symlink` home) is under
      -- the root only once resolved, the root being a resolved path itself
      local real = vim.uv.fs_realpath(path)
      if real and real ~= path then
        path = require('util.plugin').norm(real)
        norm_path = vim.fn.has('win32') == 1 and path:lower() or path
        skip = opts.relative == 'cwd' and under(cwd, norm_path)
          or under(root, norm_path)
      end
    end
    if skip then path = path:sub(skip + 1) end

    local sep = package.config:sub(1, 1)
    local parts = vim.split(path, '[\\/]')

    if opts.length ~= 0 and #parts > opts.length then
      parts =
        { parts[1], '…', unpack(parts, #parts - opts.length + 2, #parts) }
    end

    if opts.modified_hl and vim.bo.modified then
      parts[#parts] = parts[#parts] .. opts.modified_sign
      parts[#parts] = M.format(self, parts[#parts], opts.modified_hl)
    else
      parts[#parts] = M.format(self, parts[#parts], opts.filename_hl)
    end

    local dir = ''
    if #parts > 1 then
      dir = table.concat({ unpack(parts, 1, #parts - 1) }, sep)
      dir = M.format(self, dir .. sep, opts.directory_hl)
    end

    local readonly = ''
    if vim.bo.readonly then
      readonly = M.format(self, opts.readonly_icon, opts.modified_hl)
    end
    return dir .. parts[#parts] .. readonly
  end
end

--- Name of the root directory, shown only when it says something the cwd
--- does not
---@param opts? {cwd:false, subdirectory: true, parent: true, other: true, icon?:string}
function M.root_dir(opts)
  opts = vim.tbl_extend('force', {
    cwd = false,
    subdirectory = true,
    parent = true,
    other = true,
    icon = '󱉭 ',
    color = function() return { fg = Snacks.util.color('Special') } end,
  }, opts or {})

  local function get()
    local Root = require('util.root')
    local cwd = Root.cwd()
    local root = Root.get({ normalize = true })
    local name = vim.fs.basename(root)

    if root == cwd then
      return opts.cwd and name
    elseif under(cwd, root) then
      return opts.subdirectory and name
    elseif under(root, cwd) then
      return opts.parent and name
    else
      return opts.other and name
    end
  end

  return {
    function() return (opts.icon and opts.icon .. ' ') .. get() end,
    cond = function() return type(get()) == 'string' end,
    color = opts.color,
  }
end

return M
