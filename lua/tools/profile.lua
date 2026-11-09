--- Where a program spends its time, shown on its own code
---
--- `:DyProfile` runs the program of the buffer under a sampling profiler --
--- py-spy, `go test -cpuprofile`, `node --cpu-prof`, async-profiler on the
--- JVM or Linux perf -- in a terminal, so it can be read, typed to and
--- stopped with `<C-c>`. Once it exits, the profile is read into stack
--- traces, root first, and handed to perfanno, which marks the hot lines and
--- lists the hottest lines and functions. `:DyProfile memory` records
--- allocations instead -- memray, `go test -memprofile`, async-profiler's
--- `alloc` event -- weighed in bytes. `:DyProfile load` reads a profile
--- recorded elsewhere, `:DyProfile flame` draws the loaded one as a flame
--- graph.
local M = {}

local notify = require('util.notify').titled('Profile')
local system = require('util.system')

---@param msg string
local function fail(msg) notify(msg, vim.log.levels.ERROR) end

--- Milliseconds `go tool pprof` or `perf report` may take on a profile
M.TIMEOUT = 120000
--- Bytes of a profile, or of the text it is turned into, kept in memory
M.MAX_BYTES = 64 * 1024 * 1024

--- Microseconds in a unit of `go tool pprof`; a memory profile counts bytes,
--- in powers of 1024
local UNITS = {
  ns = 0.001,
  us = 1,
  ['µs'] = 1,
  ms = 1000,
  s = 1000000,
  B = 1,
  kB = 1024,
  MB = 1024 ^ 2,
  GB = 1024 ^ 3,
  TB = 1024 ^ 4,
}

--- The perfanno event of a memory profile; its counts are bytes
M.MEMORY = 'memory (bytes)'

---@class DyProfiler
---@field bin string The binary that records
---@field record fun(out: string, args: string[]): string[]
---@field default? fun(file: string): string[] What runs when no args are given
---@field linux? boolean Only runs on Linux
---@field darwin? DyProfiler What records instead on macOS
---@field env? fun(out: string, lib: string): table<string, string> The
--- environment of the program, for an agent it loads
---@field roots? string[] What marks the project the program runs from
---@field memory? DyProfiler What records allocations instead
---@field posix? boolean Only runs on Linux and macOS
---@field ext? string The extension of the profile it writes
---@field dir? boolean It writes a directory of profiles
---@field mason? string The Mason package that installs `bin`

-- memray runs the script under the Python it is installed with: a project's
-- dependencies need it installed in the project's virtual environment
---@type DyProfiler
local memray = {
  bin = 'memray',
  posix = true,
  ext = '.bin',
  mason = 'memray',
  record = function(out, args)
    return vim.list_extend({ 'memray', 'run', '-o', out }, args)
  end,
  default = function(file) return { file } end,
}
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
  memory = memray,
}
local go = {
  bin = 'go',
  ext = '.pprof',
  record = function(out, args)
    return vim.list_extend({ 'go', 'test', '-cpuprofile', out }, args)
  end,
  default = function() return {} end,
  -- Every allocation, not one per 512 KiB, so small hot ones show too
  memory = {
    bin = 'go',
    ext = '.pprof',
    record = function(out, args)
      return vim.list_extend(
        { 'go', 'test', '-memprofile', out, '-memprofilerate=1' },
        args
      )
    end,
    default = function() return {} end,
  },
}
local node = {
  bin = 'node',
  dir = true,
  -- `out` is a directory: node names the file after the time and process
  record = function(out, args)
    return vim.list_extend(
      { 'node', '--cpu-prof', '--cpu-prof-dir', out },
      args
    )
  end,
  default = function(file) return { file } end,
}
-- macOS has no perf; samply samples a native program there, and its sidecar
-- names each address with the file and line of every inlined frame
local samply = {
  bin = 'samply',
  ext = '.json.gz',
  record = function(out, args)
    return vim.list_extend({
      'samply',
      'record',
      '--save-only',
      '--unstable-presymbolicate',
      '-o',
      out,
      '--',
    }, args)
  end,
}
local perf = {
  bin = 'perf',
  linux = true,
  darwin = samply,
  ext = '.perf.data',
  record = function(out, args)
    return vim.list_extend(
      { 'perf', 'record', '--call-graph', 'dwarf', '-o', out, '--' },
      args
    )
  end,
}

-- Any JVM the command starts loads the agent, so the program may be `java`,
-- `./mvnw` or `./gradlew` alike; each writes its own file, by pid, as
-- collapsed stacks with line numbers
---@param event string The options of async-profiler choosing what it counts
---@param suffix string The end of each file's name
---@return DyProfiler
local function jvm_profiler(event, suffix)
  return {
    bin = 'java',
    dir = true,
    record = function(_, args) return args end,
    env = function(out, lib)
      local agent = ('-agentpath:%s=start,%s,collapsed,lines,file=%s/%%p%s'):format(
        lib,
        event,
        out,
        suffix
      )
      local current = vim.env.JAVA_TOOL_OPTIONS
      return {
        JAVA_TOOL_OPTIONS = current and (current .. ' ' .. agent) or agent,
      }
    end,
    roots = {
      'pom.xml',
      'build.gradle',
      'build.gradle.kts',
      'settings.gradle',
      'settings.gradle.kts',
      'build.sbt',
    },
  }
end
local jvm = jvm_profiler('event=cpu,interval=10ms', '.collapsed')
-- `total` weighs each stack by the bytes it allocated, not by samples
jvm.memory = jvm_profiler('event=alloc,total', '.alloc.collapsed')

--- The agent library of async-profiler, when Mason has it
---@return string?
function M.async_profiler()
  local lib = vim.fn.expand('$MASON/share/async-profiler/libasyncProfiler')
  return vim.uv.fs_stat(lib) and lib or nil
end

--- The profiler of each filetype
---@type table<string, DyProfiler>
M.PROFILERS = {
  java = jvm,
  kotlin = jvm,
  scala = jvm,
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

--- Sources read when looking for the file of a JVM class, at most
M.MAX_SOURCES = 20000

--- Directories that hold no source of the project's own
local SKIP = {
  ['.git'] = true,
  ['.gradle'] = true,
  build = true,
  target = true,
  out = true,
  node_modules = true,
}
local JVM_SOURCES = { java = true, kt = true, scala = true, groovy = true }

--- The JVM sources under `root`, by their name without extension
---@param root string
---@return table<string, string[]>
local function jvm_sources(root)
  local by_name, seen = {}, 0
  local function walk(dir)
    for name, kind in vim.fs.dir(dir) do
      if seen >= M.MAX_SOURCES then return end
      local path = dir .. '/' .. name
      if kind == 'directory' and not SKIP[name] then
        walk(path)
      elseif kind == 'file' then
        local base, ext = name:match('^(.+)%.(%w+)$')
        if base and JVM_SOURCES[ext] then
          seen = seen + 1
          by_name[base] = by_name[base] or {}
          table.insert(by_name[base], path)
        end
      end
    end
  end
  walk(root)
  return by_name
end

--- Collapsed stacks of async-profiler, `pkg/Class.method:line` frames, with
--- each frame of the project's own code given its source file under `root`
---@param lines string[]
---@param root string
---@param event? string What the counts are, `time` unless given
---@return table<string, table[]>
function M.parse_jvm(lines, root, event)
  local sources = jvm_sources(root)
  local found = {}
  ---@param class string `com/acme/Bar$Inner`
  ---@return string?
  local function source(class)
    local outer = class:match('^[^$]+')
    if found[outer] == nil then
      found[outer] = false
      -- `com/acme/Bar` is the source whose path, extension aside, ends so
      for _, path in ipairs(sources[outer:match('[^/]+$')] or {}) do
        local stem = path:gsub('%.%w+$', '')
        if vim.endswith(stem, '/' .. outer) then
          found[outer] = path
          break
        end
      end
    end
    return found[outer] or nil
  end
  local traces = {}
  for _, line in ipairs(lines) do
    local stack, count = line:match('^(.-)%s+(%d+)$')
    if stack and stack ~= '' and tonumber(count) > 0 then
      local frames = {}
      for text in stack:gmatch('[^;]+') do
        local class, method, lnum = text:match('^(.+)%.([^.]+):(%d+)$')
        local file = class and source(class)
        table.insert(frames, file and {
          symbol = class:match('[^/]+$') .. '.' .. method,
          file = file,
          linenr = tonumber(lnum),
        } or { symbol = text })
      end
      table.insert(traces, { count = tonumber(count), frames = frames })
    end
  end
  return { [event or 'time'] = traces }
end

--- The fields of a CSV line; a quoted field may hold commas and `""`
---@param line string
---@return string[]
local function csv_fields(line)
  local fields, i = {}, 1
  while i <= #line + 1 do
    if line:sub(i, i) == '"' then
      local value, j = '', i + 1
      while true do
        local quote = line:find('"', j, true)
        -- shortcut: a quoted field spanning lines is dropped; memray only
        -- quotes names, which hold no newline
        if not quote then return fields end
        value = value .. line:sub(j, quote - 1)
        if line:sub(quote + 1, quote + 1) ~= '"' then
          i = quote + 2
          break
        end
        value, j = value .. '"', quote + 2
      end
      table.insert(fields, value)
    else
      local comma = line:find(',', i, true) or #line + 1
      table.insert(fields, line:sub(i, comma - 1))
      i = comma + 1
    end
  end
  return fields
end

--- `memray transform csv` output: the allocations live at the peak, each
--- with its size and its stack, `func;file;line` frames, leaf first, joined
--- by `|`; a relative file is taken from `root`
---@param lines string[]
---@param root string
---@return table<string, table[]>
function M.parse_memray(lines, root)
  local traces = {}
  for _, line in ipairs(lines) do
    local fields = csv_fields(line)
    local size = tonumber(fields[3])
    if #fields >= 6 and size and size > 0 then
      local frames = {}
      for text in fields[6]:gmatch('[^|]+') do
        local symbol, file, lnum = text:match('^(.*);(.-);(%d+)$')
        if not file or file:match('^<') then
          table.insert(frames, 1, { symbol = symbol or text })
        else
          if not vim.startswith(file, '/') then
            file = vim.fs.normalize(vim.fs.joinpath(root, file))
          end
          table.insert(
            frames,
            1,
            { symbol = symbol, file = file, linenr = tonumber(lnum) }
          )
        end
      end
      if #frames > 0 then
        table.insert(traces, { count = size, frames = frames })
      end
    end
  end
  return { [M.MEMORY] = traces }
end

--- A profile samply saved -- the Firefox Profiler's processed format, with
--- addresses only -- named through its `.syms.json` sidecar: each sampled
--- address gives the function, file and line of every frame inlined there.
--- An address the sidecar does not list keeps the name of the symbol whose
--- range holds it, without a line.
---@param profile table
---@param syms? table
---@return table<string, table[]>
function M.parse_samply(profile, syms)
  local strings = (syms or {}).string_table or {}
  local by_lib = {}
  for _, data in ipairs((syms or {}).data or {}) do
    local known = {}
    for _, pair in ipairs(data.known_addresses or {}) do
      known[pair[1]] = data.symbol_table[pair[2] + 1]
    end
    by_lib[data.debug_name or ''] =
      { known = known, symbols = data.symbol_table or {} }
  end
  local function at(column, index)
    local value = column and column[index + 1]
    if value == vim.NIL then return nil end
    return value
  end
  local traces = {}
  for _, thread in ipairs(profile.threads or {}) do
    local stacks, frames, funcs =
      thread.stackTable, thread.frameTable, thread.funcTable
    local names = thread.stringArray or {}
    ---@return table[]
    local function frames_of(f)
      local address = at(frames.address, f)
      local func = at(frames.func, f)
      local resource = func and at(funcs.resource, func)
      local lib = resource and at(thread.resourceTable.lib, resource)
      local name = lib and profile.libs[lib + 1]
      local sym = name and by_lib[name.debugName or name.name]
      local entry = sym and sym.known[address]
      if entry and entry.frames then
        local out = {}
        -- The sidecar lists the innermost first; a trace starts at the root
        for i = #entry.frames, 1, -1 do
          local inlined = entry.frames[i]
          table.insert(out, {
            symbol = strings[inlined['function'] + 1],
            file = strings[inlined.file + 1],
            linenr = inlined.line,
          })
        end
        return out
      end
      for _, candidate in ipairs(sym and sym.symbols or {}) do
        if
          address
          and address >= candidate.rva
          and address < candidate.rva + candidate.size
        then
          return { { symbol = strings[candidate.symbol + 1] } }
        end
      end
      return { { symbol = func and names[at(funcs.name, func) + 1] or '?' } }
    end
    local by_stack = {}
    local samples = thread.samples or {}
    for i = 0, (samples.length or #(samples.stack or {})) - 1 do
      local stack = at(samples.stack, i)
      if stack then
        local trace = by_stack[stack]
        if not trace then
          local chain, s = {}, stack
          while s do
            table.insert(chain, 1, at(stacks.frame, s))
            s = at(stacks.prefix, s)
          end
          trace = { count = 0, frames = {} }
          for _, f in ipairs(chain) do
            vim.list_extend(trace.frames, frames_of(f))
          end
          by_stack[stack] = trace
          table.insert(traces, trace)
        end
        trace.count = trace.count + (at(samples.weight, i) or 1)
      end
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
--- leaf first, its value on the first line after any `key: value` labels;
--- a heap or allocation profile counts bytes
---@param lines string[]
---@return table<string, table[]>
function M.parse_pprof(lines)
  local traces, current, event = {}, nil, 'time'
  local function close()
    if current and current.count > 0 and #current.frames > 0 then
      current.frames = vim.fn.reverse(current.frames)
      table.insert(traces, current)
    end
    current = nil
  end
  for _, line in ipairs(lines) do
    local kind = not current and line:match('^Type: (%S+)')
    if kind then
      event = kind == 'cpu' and 'time'
        or kind:match('_space$') and M.MEMORY
        or kind
    elseif line:match('^%-+%+%-+$') then
      close()
      current = { count = 0, frames = {} }
    elseif
      current
      -- not a label of the samples below, `bytes:  1MB`
      and not (#current.frames == 0 and line:match('^%s*[%w_]+:%s'))
    then
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
  return { [event] = traces }
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

--- The profiler of `filetype` on this system, of its time or its memory
---@param filetype string
---@param memory? boolean
---@return DyProfiler?
---@return string? err
function M.profiler(filetype, memory)
  local function known(of_memory)
    local names = vim.tbl_filter(
      function(name) return not of_memory or M.PROFILERS[name].memory end,
      vim.tbl_keys(M.PROFILERS)
    )
    table.sort(names)
    return table.concat(names, ', ')
  end
  local profiler = M.PROFILERS[filetype]
  if not profiler then
    return nil, ('No profiler for %s; one of %s'):format(filetype, known())
  end
  if memory then
    profiler = profiler.memory
    if not profiler then
      return nil,
        ('No memory profiler for %s; one of %s'):format(filetype, known(true))
    end
  end
  local system_name = vim.uv.os_uname().sysname
  if profiler.linux and system_name ~= 'Linux' then
    if not (profiler.darwin and system_name == 'Darwin') then
      return nil, ('%s only runs on Linux'):format(profiler.bin)
    end
    profiler = profiler.darwin
  end
  if profiler.posix and system_name ~= 'Linux' and system_name ~= 'Darwin' then
    return nil, ('%s only runs on Linux and macOS'):format(profiler.bin)
  end
  return profiler
end

--- The command recording `file`'s program into `out`, and where it runs
---@param filetype string
---@param file string The buffer's file
---@param args string[] The program and its arguments, or none for the default
---@param out string Where the profile goes
---@param memory? boolean Record allocations rather than time
---@return string[]? cmd
---@return string cwd_or_err
---@return table<string, string>? env
function M.command(filetype, file, args, out, memory)
  local profiler, err = M.profiler(filetype, memory)
  if not profiler then
    return nil, err --[[@as string]]
  end
  if #args == 0 then
    if not profiler.default then
      return nil, 'Give the program to profile: `:DyProfile ./target/debug/app`'
    end
    args = profiler.default(file)
  end
  local cwd = profiler.roots and vim.fs.root(file, profiler.roots)
    or vim.fs.dirname(file)
  local env
  if profiler.env then
    local lib = M.async_profiler()
    if not lib then
      require('util.lazy_install').install_once('async-profiler')
      return nil,
        'Installing async-profiler with Mason; profile again once it is done'
    end
    env = profiler.env(out, lib)
  end
  return profiler.record(out, args), cwd, env
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
  M.last = traces
  require('perfanno').load_traces(traces)
  notify(
    ('%s loaded: `<leader>dpf` hottest functions, `<leader>dpl` lines'):format(
      vim.fn.fnamemodify(source, ':t')
    )
  )
end

--- Read the profile at `path` -- pprof, `.cpuprofile`, `perf.data`, memray
--- `.bin` or its `.csv`, a directory of `.cpuprofile` or of async-profiler
--- `.collapsed` files (`.alloc.collapsed` for allocations), or collapsed
--- stacks -- and show it
---@param path string
---@param root? string The project of a JVM or memray profile, the working
--- directory unless given
function M.load(path, root)
  path = vim.fs.normalize(vim.fn.fnamemodify(path, ':p'))
  if vim.fn.isdirectory(path) == 1 then
    local traces = {}
    local function add(parsed)
      for event, list in pairs(parsed) do
        traces[event] = vim.list_extend(traces[event] or {}, list)
      end
    end
    local names = {}
    for name in vim.fs.dir(path) do
      table.insert(names, name)
    end
    table.sort(names)
    for _, name in ipairs(names) do
      local text, err
      if name:match('%.cpuprofile$') or name:match('%.collapsed$') then
        text, err = read(vim.fs.joinpath(path, name))
        if not text then return fail(err) end
      end
      if name:match('%.cpuprofile$') then
        local ok, profile = pcall(vim.json.decode, text)
        if not ok then return fail(('%s: %s'):format(name, profile)) end
        add(M.parse_cpuprofile(profile))
      elseif name:match('%.collapsed$') then
        add(
          M.parse_jvm(
            vim.split(text, '\n'),
            root or vim.fn.getcwd(),
            name:match('%.alloc%.collapsed$') and M.MEMORY or nil
          )
        )
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
  if path:match('%.p?prof$') or path:match('%.out$') then
    return from(
      { 'go', 'tool', 'pprof', '-traces', '-lines', path },
      'go tool pprof',
      M.parse_pprof
    )
  end
  if path:match('%.bin$') then
    local csv = vim.fn.tempname() .. '.csv'
    return system.run(
      { 'memray', 'transform', 'csv', '-o', csv, path },
      { timeout = M.TIMEOUT },
      function(result)
        if result.missing then
          require('util.lazy_install').install_once('memray')
          return fail(
            'Installing memray with Mason; load again once it is done'
          )
        end
        local text, err = read(csv)
        os.remove(csv)
        if result.code ~= 0 or not text then
          return fail(
            result.code ~= 0 and system.failure(result, 'memray transform')
              or err --[[@as string]]
          )
        end
        show(
          M.parse_memray(vim.split(text, '\n'), root or vim.fn.getcwd()),
          path
        )
      end
    )
  end
  if path:match('%.json%.gz$') then
    return system.run(
      { 'gzip', '-dc', path },
      { timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
      function(result)
        if result.code ~= 0 or result.cut then
          return fail(system.failure(result, 'gzip'))
        end
        local ok, saved = pcall(vim.json.decode, result.stdout)
        if not ok then return fail(('%s: %s'):format(path, saved)) end
        local sidecar = read(path:gsub('%.gz$', '') .. '.syms.json')
        local syms = sidecar and select(2, pcall(vim.json.decode, sidecar))
        show(M.parse_samply(saved, type(syms) == 'table' and syms or nil), path)
      end
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
  if path:match('%.csv$') then
    return show(
      M.parse_memray(vim.split(text, '\n'), root or vim.fn.getcwd()),
      path
    )
  end
  show(M.parse_collapsed(vim.split(text, '\n')), path)
end

--- Profile the program of the current buffer, or `args`, in a terminal,
--- and show the profile once it exits
---@param args string[]
---@param memory? boolean Record allocations rather than time
function M.run(args, memory)
  local file = vim.api.nvim_buf_get_name(0)
  local filetype = vim.bo.filetype
  local profiler, err = M.profiler(filetype, memory)
  if not profiler then
    return fail(err --[[@as string]])
  end
  local out = vim.fn.tempname() .. (profiler.ext or '')
  if profiler.dir then vim.fn.mkdir(out, 'p') end
  local cmd, cwd, env = M.command(filetype, file, args, out, memory)
  if not cmd then return fail(cwd) end
  -- `./mvnw` is found from the project, not from here
  if not cmd[1]:find('/') and vim.fn.executable(cmd[1]) == 0 then
    if profiler.mason and cmd[1] == profiler.bin then
      require('util.lazy_install').install_once(profiler.mason)
      return fail(
        ('%s is not installed; installing it with Mason, profile again once it is done'):format(
          cmd[1]
        )
      )
    end
    return fail(('%s is not installed'):format(cmd[1]))
  end
  if file == '' then cwd = vim.fn.getcwd() end
  vim.cmd('botright 12split')
  vim.api.nvim_win_set_buf(0, vim.api.nvim_create_buf(false, true))
  vim.fn.jobstart(cmd, {
    term = true,
    cwd = cwd,
    env = env,
    on_exit = function(_, code)
      vim.schedule(function()
        if not vim.uv.fs_stat(out) then
          return fail(('%s wrote no profile (exit %d)'):format(cmd[1], code))
        end
        M.load(out, cwd)
      end)
    end,
  })
  vim.cmd.startinsert()
end

--- `traces` as collapsed stacks, `root;...;leaf count` per line; a frame is
--- its symbol and `file:line` where it has them
---@param traces table[]
---@return string[]
function M.collapsed(traces)
  local lines = {}
  for _, trace in ipairs(traces) do
    local frames = {}
    for _, f in ipairs(trace.frames) do
      local where = f.file and ('%s:%d'):format(f.file, f.linenr) or nil
      local text = f.symbol and where and (f.symbol .. ' ' .. where)
        or f.symbol
        or where
        or '?'
      table.insert(frames, (text:gsub(';', ':')))
    end
    table.insert(
      lines,
      ('%s %d'):format(table.concat(frames, ';'), trace.count)
    )
  end
  return lines
end

--- Draw the loaded profile as a flame graph and open it
function M.flame()
  local traces = M.last
  if not traces then
    return fail('No profile is loaded: `:DyProfile` or `:DyProfile load` first')
  end
  local event = traces.time and 'time' or next(traces)
  local cmd =
    { 'inferno-flamegraph', '--title', ('DyNeo profile (%s)'):format(event) }
  if event == M.MEMORY then
    vim.list_extend(cmd, { '--countname', 'bytes', '--colors', 'mem' })
  end
  system.run(
    cmd,
    { stdin = M.collapsed(traces[event]), timeout = M.TIMEOUT },
    function(result)
      if result.missing then
        require('util.lazy_install').install_once('inferno')
        return notify(
          'Installing inferno with Mason; draw again once it is done',
          vim.log.levels.WARN
        )
      end
      if result.code ~= 0 or result.cut then
        return fail(system.failure(result, 'inferno-flamegraph'))
      end
      local svg = vim.fn.tempname() .. '.svg'
      vim.fn.writefile(
        vim.split(result.stdout, '\n', { trimempty = true }),
        svg
      )
      vim.ui.open(svg)
    end
  )
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
