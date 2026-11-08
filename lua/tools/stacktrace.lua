--- A stack trace as a quickfix list of the project's files and lines
---
--- The frames of Java, Kotlin, Scala, Python, Go, Rust and Node traces are
--- read by the patterns of `M.FORMATS`, one entry per format. A JVM frame
--- names a class and a bare file name, found in the project by its package
--- path; the others carry a path, read against the project root when
--- relative. Frames outside the project -- the JDK, site-packages, GOROOT,
--- `node_modules`, the cargo registry, or nowhere to be found -- stay in the
--- list as `I` items, so the project's own frames stand out. The trace is
--- only read here; it is never sent anywhere.
local M = {}

local notify = require('util.notify').titled('Stack trace')

--- Milliseconds the project's file list may take
M.TIMEOUT = 10000

--- Bytes of the project's file list kept, to find the JVM classes in
M.MAX_LIST = 8 * 1024 * 1024

--- Frames listed; a longer trace is cut, and says so
M.MAX_FRAMES = 1000

--- Filetypes whose buffer is read whole when no range is given
M.LOG_FILETYPES = { 'dylog', 'log' }

--- Directories of a path that put it outside the project, even under its
--- root
M.EXTERNAL = {
  '/node_modules/',
  '/site-packages/',
  '/dist-packages/',
  '/.cargo/',
  '/.rustup/',
  '/pkg/mod/',
}

---@class DyStackFrame
---@field fn? string The function, as the trace names it
---@field file string A path, or a bare file name for a JVM frame
---@field lnum integer
---@field col? integer
---@field pkg? string The package directory of a JVM frame (`com/acme`)

---@class DyStackFormat
---@field name string
---@field pattern string Lua pattern of a frame line
---@field frame fun(...: string): DyStackFrame From the captures
---@field prev? string Pattern of the line above, capturing the function

--- The formats of a frame, tried in order on each line
---@type DyStackFormat[]
M.FORMATS = {
  {
    -- `at com.acme.Foo$Inner.run(Foo.java:7)`, maybe with a module prefix
    name = 'jvm',
    pattern = '^%s*at%s+([^%s(]+)%(([^:()]+):(%d+)%)',
    frame = function(fn, file, lnum)
      local class = fn:gsub('^[^/]*/', ''):match('^(.*)%.[^.]+$') or ''
      return {
        fn = fn,
        file = file,
        lnum = tonumber(lnum),
        pkg = (class:match('^(.*)%.[^.]+$') or ''):gsub('%.', '/'),
      }
    end,
  },
  {
    name = 'python',
    pattern = '^%s*File "(.-)", line (%d+), in (.+)$',
    frame = function(file, lnum, fn)
      return { fn = fn, file = file, lnum = tonumber(lnum) }
    end,
  },
  {
    -- `\t/srv/app/main.go:12 +0x1f`, under the line naming the function
    name = 'go',
    pattern = '^%s+(%S+%.go):(%d+)',
    prev = '^(%S.-)%s*$',
    frame = function(file, lnum) return { file = file, lnum = tonumber(lnum) } end,
  },
  {
    -- `at ./src/main.rs:5:9` of RUST_BACKTRACE, under `0: app::run`
    name = 'rust',
    pattern = '^%s*at%s+(.-%.rs):(%d+):(%d+)$',
    prev = '^%s*%d+:%s+(%S+)',
    frame = function(file, lnum, col)
      return { file = file, lnum = tonumber(lnum), col = tonumber(col) }
    end,
  },
  {
    name = 'node',
    pattern = '^%s*at%s+(.-)%s+%((.-):(%d+):(%d+)%)$',
    frame = function(fn, file, lnum, col)
      return {
        fn = fn,
        file = file:gsub('^file://', ''),
        lnum = tonumber(lnum),
        col = tonumber(col),
      }
    end,
  },
  {
    name = 'node',
    pattern = '^%s*at%s+(.-):(%d+):(%d+)$',
    frame = function(file, lnum, col)
      return {
        file = file:gsub('^file://', ''),
        lnum = tonumber(lnum),
        col = tonumber(col),
      }
    end,
  },
}

--- The frames of the trace in `lines`, in order
---@param lines string[]
---@return DyStackFrame[]
function M.parse(lines)
  local frames = {}
  for i, line in ipairs(lines) do
    for _, format in ipairs(M.FORMATS) do
      local captures = { line:match(format.pattern) }
      if #captures > 0 then
        local frame = format.frame(unpack(captures))
        if format.prev and lines[i - 1] then
          frame.fn = lines[i - 1]:match(format.prev)
        end
        table.insert(frames, frame)
        break
      end
    end
  end
  return frames
end

--- The lines `:DyStackTrace` reads: the range when given, else a log buffer
--- whole, else the clipboard, else the unnamed register
---@param args { range: integer, line1?: integer, line2?: integer }
---@return string[]
function M.input(args)
  if args.range > 0 then
    return vim.api.nvim_buf_get_lines(0, args.line1 - 1, args.line2, false)
  end
  if vim.tbl_contains(M.LOG_FILETYPES, vim.bo.filetype) then
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
  end
  local lines = {}
  for _, reg in ipairs({ '+', '"' }) do
    -- no clipboard provider is an error, not an empty register
    local ok, text = pcall(vim.fn.getreg, reg)
    lines = ok and vim.split(text or '', '\n', { trimempty = true }) or {}
    if #M.parse(lines) > 0 then return lines end
  end
  return lines
end

--- Where `frame` is, and whether that is in the project
---@param frame DyStackFrame
---@param root string Resolved
---@param files? string[] The project's files, relative to `root`
---@return string? path
---@return boolean in_project
local function locate(frame, root, files)
  local path
  if frame.pkg then
    local suffix = (frame.pkg ~= '' and frame.pkg .. '/' or '') .. frame.file
    for _, file in ipairs(files or {}) do
      if file == suffix or file:sub(-#suffix - 1) == '/' .. suffix then
        path = vim.fs.joinpath(root, file)
        break
      end
    end
  else
    path = frame.file
    if path:sub(1, 1) ~= '/' then path = vim.fs.joinpath(root, path) end
  end
  path = path and vim.uv.fs_realpath(path)
  if not path then return nil, false end
  local util_root = require('util.root')
  if not util_root.contains(root, path) then return path, false end
  local inner = path:sub(#root + 1)
  for _, dir in ipairs(M.EXTERNAL) do
    if inner:find(dir, 1, true) then return path, false end
  end
  return path, true
end

--- Fill the quickfix list with `frames` and land on the project's first
---@param frames DyStackFrame[]
---@param root string Resolved
---@param files? string[]
local function show(frames, root, files)
  local items, first = {}, nil
  for _, frame in ipairs(frames) do
    local path, in_project = locate(frame, root, files)
    local where = ('%s:%d'):format(frame.file, frame.lnum)
    table.insert(items, {
      filename = path,
      lnum = frame.lnum,
      col = frame.col or 0,
      type = not in_project and 'I' or nil,
      -- a frame found nowhere keeps where the trace said it was
      text = path and (frame.fn or where)
        or ((frame.fn and frame.fn .. ' ' or '') .. '(' .. where .. ')'),
    })
    if in_project and not first then first = #items end
  end
  vim.fn.setqflist({}, ' ', {
    title = 'Stack trace',
    items = items,
    idx = first or 1,
  })
  vim.cmd('botright copen')
  if first then
    vim.cmd('cc ' .. first)
  else
    notify('No frame of the trace is in the project', vim.log.levels.WARN)
  end
end

--- List the frames of the trace in `lines`, found in `root`, the project of
--- the buffer unless given
---@param lines string[]
---@param root? string
function M.run(lines, root)
  local frames = M.parse(lines)
  if #frames == 0 then
    notify('No stack frame found in the trace', vim.log.levels.WARN)
    return
  end
  if #frames > M.MAX_FRAMES then
    frames = vim.list_slice(frames, 1, M.MAX_FRAMES)
    notify(
      ('Only the first %d frames are listed'):format(M.MAX_FRAMES),
      vim.log.levels.WARN
    )
  end
  root = root or require('util.root')()
  root = vim.uv.fs_realpath(root) or root
  local jvm = vim.iter(frames):any(function(f) return f.pkg ~= nil end)
  if not jvm then return show(frames, root) end

  -- a JVM frame names a class: find its file among the project's
  local system = require('util.system')
  local opts = { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_LIST }
  local function listed(result)
    if result.cut then
      notify(
        'The project lists too many files; some classes may not be found',
        vim.log.levels.WARN
      )
    end
    show(frames, root, vim.split(result.stdout, '\n', { trimempty = true }))
  end
  system.run(
    { 'git', 'ls-files', '--cached', '--others', '--exclude-standard' },
    opts,
    function(result)
      if result.code == 0 or result.cut then return listed(result) end
      -- not a git repository
      system.run({ 'rg', '--files' }, opts, function(rg)
        if rg.code == 0 or rg.cut then return listed(rg) end
        notify(
          'Cannot list the files of '
            .. root
            .. ', so no class is found: '
            .. system.failure(rg, 'rg --files'),
          vim.log.levels.WARN
        )
        show(frames, root)
      end)
    end
  )
end

return M
