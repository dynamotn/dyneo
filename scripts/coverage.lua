-- Draw the lcov report from the stats the specs wrote under luacov, and
-- print the totals. Run by `scripts/coverage.sh` after the specs:
--
--   nvim --clean --headless -l scripts/coverage.lua
--
-- A file under a counted directory that no spec loaded is added with every
-- line missed, so the report says what is untested instead of leaving it
-- out, which is what luacov does without luafilesystem. Paths in the report
-- are relative to the repository, as Coveralls wants them.

local root = vim.fs.dirname(vim.fs.dirname(debug.getinfo(1, 'S').source:sub(2)))
root = vim.fs.normalize(vim.fn.fnamemodify(root, ':p'))

---@param message string
local function die(message)
  io.stderr:write('coverage: ' .. message .. '\n')
  os.exit(1)
end

-- The same checkouts `tests/minimal_init.lua` made for the specs
local luacov = vim.fs.joinpath(root, '.tests', 'luacov')
local lcov = vim.fs.joinpath(root, '.tests', 'luacov-reporter-lcov')
if not vim.uv.fs_stat(luacov) or not vim.uv.fs_stat(lcov) then
  die('luacov is not checked out; run scripts/coverage.sh')
end
package.path = table.concat({
  vim.fs.joinpath(luacov, 'src', '?.lua'),
  vim.fs.joinpath(lcov, '?.lua'),
  package.path,
}, ';')

local coverage = dofile(vim.fs.joinpath(root, 'tests', 'luacov.lua'))(root)
local runner = require('luacov.runner')
local stats = require('luacov.stats')
runner.load_config(coverage.luacov)

local data = stats.load(coverage.luacov.statsfile)
if not data then
  die(
    'no stats in ' .. coverage.luacov.statsfile .. '; run scripts/coverage.sh'
  )
end
for _, sub in ipairs(coverage.sources) do
  local files = vim.fs.find(
    function(name) return name:match('%.lua$') ~= nil end,
    { path = vim.fs.joinpath(root, sub), type = 'file', limit = math.huge }
  )
  for _, file in ipairs(files) do
    if not data[file] and runner.file_included(file) then
      data[file] = { max = 0, max_hits = 0 }
    end
  end
end
stats.save(coverage.luacov.statsfile, data)

require('luacov.reporter.lcov').report()

-- luacov reads the source to decide which lines count, and takes a line
-- that only continues a call -- a table of options as an argument -- for
-- one that runs; LuaJIT gives such a line no bytecode of its own, so the
-- hook never reports it and it reads as missed however often the call ran.
-- The lines that can be reported are those with bytecode, read off the
-- compiled file and its nested functions, as cluacov does in C. A line
-- holding nothing but the jump of a test on the line before it -- the
-- second operand of an `and` or `or` split over lines -- is not one of
-- them: the test takes the jump itself, and the jump never runs on its own.
local jit_util = require('jit.util')
local bcnames = require('jit.vmdef').bcnames
---@param fn function|userdata A function or a prototype of one
---@param pc integer
---@return string
local function opcode(fn, pc)
  local op = bit.band(jit_util.funcbc(fn, pc), 0xff)
  return (bcnames:sub(op * 6 + 1, op * 6 + 6):gsub(' ', ''))
end
---@param fn function|userdata A function or a prototype of one
---@param lines table<integer, true>
local function bytecode_lines(fn, lines)
  for pc = 1, jit_util.funcinfo(fn).bytecodes do
    local line = jit_util.funcinfo(fn, pc).currentline
    if line and opcode(fn, pc) ~= 'JMP' then lines[line] = true end
  end
  -- The nested functions are among the constants, from the end
  local i = 1
  while true do
    local constant = jit_util.funck(fn, -i)
    if constant == nil then break end
    if type(constant) == 'proto' then bytecode_lines(constant, lines) end
    i = i + 1
  end
end
---@param file string
---@return table<integer, true>
local function reportable(file)
  local lines = {}
  local chunk = loadfile(file)
  if chunk then bytecode_lines(chunk, lines) end
  return lines
end

local report = coverage.luacov.reportfile
local lines = vim.fn.readfile(report)
local kept = {}
local hit, found = 0, 0
local file_hit, file_found, active = 0, 0, {}
for _, line in ipairs(lines) do
  if vim.startswith(line, 'SF:') then
    active = reportable(line:sub(4))
    file_hit, file_found = 0, 0
    if vim.startswith(line, 'SF:' .. root .. '/') then
      line = 'SF:' .. line:sub(#root + 5)
    end
    table.insert(kept, line)
  elseif vim.startswith(line, 'DA:') then
    local number, hits = line:match('^DA:(%d+),(%d+)')
    hits = tonumber(hits)
    if hits > 0 or active[tonumber(number)] then
      file_found = file_found + 1
      if hits > 0 then file_hit = file_hit + 1 end
      table.insert(kept, line)
    end
  elseif vim.startswith(line, 'LH:') then
    hit = hit + file_hit
    table.insert(kept, 'LH:' .. file_hit)
  elseif vim.startswith(line, 'LF:') then
    found = found + file_found
    table.insert(kept, 'LF:' .. file_found)
  else
    table.insert(kept, line)
  end
end
vim.fn.writefile(kept, report)
print(
  ('coverage: %.1f%% of %d lines, report in %s'):format(
    found == 0 and 0 or hit * 100 / found,
    found,
    vim.fs.relpath(root, report) or report
  )
)
