--- Where a program spends its time, shown on its own code
---
--- `:DyProfile` runs the program of the buffer under a sampling profiler --
--- py-spy, `go test -cpuprofile`, `node --cpu-prof` or Linux perf -- in a
--- terminal, so it can be read, typed to and stopped with `<C-c>`. Once it
--- exits, the profile is read into stack traces, root first, and handed to
--- perfanno, which marks the hot lines and lists the hottest lines and
--- functions. `:DyProfile load` reads a profile recorded elsewhere.
local M = {}

local notify = require('util.notify').titled('Profile')
local system = require('util.system')

---@param msg string
local function fail(msg) notify(msg, vim.log.levels.ERROR) end

--- Milliseconds `go tool pprof` or `perf report` may take on a profile
M.TIMEOUT = 120000
--- Bytes of a profile, or of the text it is turned into, kept in memory
M.MAX_BYTES = 64 * 1024 * 1024

--- Microseconds in a unit of `go tool pprof`; a memory profile counts bytes
local UNITS = {
  ns = 0.001,
  us = 1,
  ['µs'] = 1,
  ms = 1000,
  s = 1000000,
  B = 1,
  kB = 1000,
  MB = 1000000,
  GB = 1000000000,
}

---@class DyProfiler
---@field bin string The binary that records
---@field record fun(out: string, args: string[]): string[]
---@field default? fun(file: string): string[] What runs when no args are given
---@field linux? boolean Only runs on Linux

---@type DyProfiler
local py_spy = {
  bin = 'py-spy',
  record = function(out, args)
    return vim.list_extend({
      'py-spy',
      'record',
      '--format',
      'raw',
      '--full-filenames',
      '-o',
      out,
      '--',
    }, args)
  end,
  default = function(file) return { 'python3', file } end,
}
local go = {
  bin = 'go',
  record = function(out, args)
    return vim.list_extend({ 'go', 'test', '-cpuprofile', out }, args)
  end,
  default = function() return {} end,
}
local node = {
  bin = 'node',
  -- `out` is a directory: node names the file after the time and process
  record = function(out, args)
    return vim.list_extend(
      { 'node', '--cpu-prof', '--cpu-prof-dir', out },
      args
    )
  end,
  default = function(file) return { file } end,
}
local perf = {
  bin = 'perf',
  linux = true,
  record = function(out, args)
    return vim.list_extend(
      { 'perf', 'record', '--call-graph', 'dwarf', '-o', out, '--' },
      args
    )
  end,
}

--- The profiler of each filetype
---@type table<string, DyProfiler>
M.PROFILERS = {
  python = py_spy,
  go = go,
  javascript = node,
  typescript = node,
  c = perf,
  cpp = perf,
  rust = perf,
  zig = perf,
}

--- A frame of a stack: `sym (/f:1)` (py-spy), `sym /f:1` or `/f:1`
--- (flamegraph, perf, pprof); anything else is a symbol alone
---@param text string
---@return table
local function frame(text)
  local symbol, file, line = text:match('^(.-) %((/.+):(%d+)%)$')
  if not symbol then
    symbol, file, line = text:match('^(.-)%s*(/.+):(%d+)$')
  end
  if not file then return { symbol = text } end
  return {
    symbol = symbol ~= '' and symbol or nil,
    file = file,
    linenr = tonumber(line),
  }
end

--- Collapsed stacks, as py-spy `--format raw` and flamegraph.pl write them:
--- `root;...;leaf count` per line
---@param lines string[]
---@return table<string, table[]>
function M.parse_collapsed(lines)
  local traces = {}
  for _, line in ipairs(lines) do
    local stack, count = line:match('^(.-)%s+(%d+)$')
    if stack and stack ~= '' and tonumber(count) > 0 then
      local frames = {}
      for text in stack:gmatch('[^;]+') do
        table.insert(frames, frame(text))
      end
      table.insert(traces, { count = tonumber(count), frames = frames })
    end
  end
  return { time = traces }
end

--- `perf report -g folded,0,caller,...` output: stacks per event, root first
---@param lines string[]
---@return table<string, table[]>
function M.parse_perf_report(lines)
  local traces, event = {}, nil
  for _, line in ipairs(lines) do
    local name = line:match("^# Samples: %S+%s+of event '(.*)'")
    if name then
      event = name
      traces[event] = traces[event] or {}
    elseif event then
      local count, stack = line:match('^(%d+) (.+)$')
      if count and tonumber(count) > 0 then
        local frames = {}
        for text in stack:gmatch('[^;]+') do
          table.insert(frames, frame(text))
        end
        table.insert(
          traces[event],
          { count = tonumber(count), frames = frames }
        )
      end
    end
  end
  return traces
end

--- `go tool pprof -traces -lines` output: blocks ruled by `---+---`, the
--- leaf first, its value on the first line
---@param lines string[]
---@return table<string, table[]>
function M.parse_pprof(lines)
  local traces, current = {}, nil
  local function close()
    if current and #current.frames > 0 then
      current.frames = vim.fn.reverse(current.frames)
      table.insert(traces, current)
    end
    current = nil
  end
  for _, line in ipairs(lines) do
    if line:match('^%-+%+%-+$') then
      close()
      current = { count = 0, frames = {} }
    elseif current then
      local value, unit, rest = line:match('^%s*([%d.]+)(%a*)%s+(%S.*)$')
      if value and #current.frames == 0 then
        current.count = math.floor(tonumber(value) * (UNITS[unit] or 1) + 0.5)
      else
        rest = vim.trim(line)
      end
      if rest ~= '' then
        table.insert(current.frames, frame((rest:gsub('%s+%(inline%)$', ''))))
      end
    end
  end
  close()
  return { time = traces }
end

--- A V8 `.cpuprofile`: a tree of functions, each with the samples that hit
--- it; the lines of those samples come from `positionTicks` when V8 kept
--- them, else the line the function starts on
---@param profile table
---@return table<string, table[]>
function M.parse_cpuprofile(profile)
  local nodes, parent = {}, {}
  for _, node in ipairs(profile.nodes or {}) do
    nodes[node.id] = node
    for _, child in ipairs(node.children or {}) do
      parent[child] = node.id
    end
  end
  ---@return table
  local function node_frame(node, line)
    local call = node.callFrame or {}
    local url = call.url or ''
    if not url:match('^file://') then
      return { symbol = call.functionName ~= '' and call.functionName or url }
    end
    return {
      symbol = call.functionName ~= '' and call.functionName or nil,
      file = vim.uri_to_fname(url),
      -- shortcut: a caller is marked on the line its function starts, V8
      -- keeps no call site; enough to find the hot path
      linenr = line or (call.lineNumber or 0) + 1,
    }
  end
  local traces = {}
  for _, node in ipairs(profile.nodes or {}) do
    local hits = node.hitCount or 0
    if hits > 0 then
      local stack, id = {}, parent[node.id]
      while id do
        table.insert(stack, 1, node_frame(nodes[id]))
        id = parent[id]
      end
      local function add(count, line)
        local frames = vim.deepcopy(stack)
        table.insert(frames, node_frame(node, line))
        table.insert(traces, { count = count, frames = frames })
      end
      for _, tick in ipairs(node.positionTicks or {}) do
        add(tick.ticks, tick.line)
        hits = hits - tick.ticks
      end
      if hits > 0 then add(hits) end
    end
  end
  return { time = traces }
end

--- The command recording `file`'s program into `out`, and where it runs
---@param filetype string
---@param file string The buffer's file
---@param args string[] The program and its arguments, or none for the default
---@param out string Where the profile goes
---@return string[]? cmd
---@return string cwd_or_err
function M.command(filetype, file, args, out)
  local profiler = M.PROFILERS[filetype]
  if not profiler then
    local known = vim.tbl_keys(M.PROFILERS)
    table.sort(known)
    return nil,
      ('No profiler for %s; one of %s'):format(
        filetype,
        table.concat(known, ', ')
      )
  end
  if profiler.linux and vim.uv.os_uname().sysname ~= 'Linux' then
    return nil, ('%s only runs on Linux'):format(profiler.bin)
  end
  if #args == 0 then
    if not profiler.default then
      return nil, 'Give the program to profile: `:DyProfile ./target/debug/app`'
    end
    args = profiler.default(file)
  end
  return profiler.record(out, args), vim.fs.dirname(file)
end

--- The lines of `path`, or nil with why
---@param path string
---@return string? text
---@return string? err
local function read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat then return nil, ('No profile at %s'):format(path) end
  if stat.size > M.MAX_BYTES then
    return nil, ('%s is larger than %d bytes'):format(path, M.MAX_BYTES)
  end
  local f = io.open(path, 'rb')
  if not f then return nil, ('Cannot read %s'):format(path) end
  local text = f:read('*a')
  f:close()
  return text
end

--- Hand `traces` to perfanno, or say why there is nothing to show
---@param traces table<string, table[]>
---@param source string
local function show(traces, source)
  local samples = 0
  for _, list in pairs(traces) do
    for _, trace in ipairs(list) do
      samples = samples + trace.count
    end
  end
  if samples == 0 then return fail(('%s holds no samples'):format(source)) end
  require('perfanno').load_traces(traces)
  notify(
    ('%s loaded: `<leader>dpf` hottest functions, `<leader>dpl` lines'):format(
      vim.fn.fnamemodify(source, ':t')
    )
  )
end

--- Read the profile at `path` -- pprof, `.cpuprofile`, `perf.data`, a
--- directory of `.cpuprofile` or collapsed stacks -- and show it
---@param path string
function M.load(path)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if vim.fn.isdirectory(path) == 1 then
    local traces = { time = {} }
    for name in vim.fs.dir(path) do
      if name:match('%.cpuprofile$') then
        local text, err = read(vim.fs.joinpath(path, name))
        if not text then return fail(err) end
        local ok, profile = pcall(vim.json.decode, text)
        if not ok then return fail(('%s: %s'):format(name, profile)) end
        vim.list_extend(traces.time, M.parse_cpuprofile(profile).time)
      end
    end
    return show(traces, path)
  end
  local function from(cmd, name, parse)
    system.run(
      cmd,
      { timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
      function(result)
        if result.code ~= 0 or result.cut then
          return fail(system.failure(result, name))
        end
        show(parse(vim.split(result.stdout, '\n')), path)
      end
    )
  end
  if path:match('%.pprof$') or path:match('%.prof$') then
    return from(
      { 'go', 'tool', 'pprof', '-traces', '-lines', path },
      'go tool pprof',
      M.parse_pprof
    )
  end
  if path:match('perf[^/]*%.data[^/]*$') then
    -- The arguments perfanno's own loader gives, run off the main loop
    return from({
      'perf',
      'report',
      '-g',
      'folded,0,caller,srcline,branch,count',
      '--no-children',
      '--full-source-path',
      '--stdio',
      '-i',
      path,
    }, 'perf report', M.parse_perf_report)
  end
  local text, err = read(path)
  if not text then return fail(err) end
  if path:match('%.cpuprofile$') then
    local ok, profile = pcall(vim.json.decode, text)
    if not ok then return fail(profile) end
    return show(M.parse_cpuprofile(profile), path)
  end
  show(M.parse_collapsed(vim.split(text, '\n')), path)
end

--- Profile the program of the current buffer, or `args`, in a terminal,
--- and show the profile once it exits
---@param args string[]
function M.run(args)
  local file = vim.api.nvim_buf_get_name(0)
  local filetype = vim.bo.filetype
  local profiler = M.PROFILERS[filetype]
  local out = vim.fn.tempname()
  if profiler == node then vim.fn.mkdir(out, 'p') end
  if profiler == go then out = out .. '.pprof' end
  if profiler == perf then out = out .. '.perf.data' end
  local cmd, cwd = M.command(filetype, file, args, out)
  if not cmd then return fail(cwd) end
  if vim.fn.executable(cmd[1]) == 0 then
    return fail(('%s is not installed'):format(cmd[1]))
  end
  if file == '' then cwd = vim.fn.getcwd() end
  vim.cmd('botright 12split')
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.fn.jobstart(cmd, {
    term = true,
    cwd = cwd,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.uv.fs_stat(out) then
          return fail(('%s wrote no profile (exit %d)'):format(cmd[1], code))
        end
        M.load(out)
      end)
    end,
  })
  vim.cmd.startinsert()
end

--- `:DyProfile load [file]`, asking for the file when none is given
---@param file? string
function M.load_command(file)
  if file and file ~= '' then return M.load(file) end
  vim.ui.input({ prompt = 'Profile: ', completion = 'file' }, function(answer)
    if answer and answer ~= '' then M.load(answer) end
  end)
end

return M
