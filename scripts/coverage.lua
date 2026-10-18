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

local report = coverage.luacov.reportfile
local lines = vim.fn.readfile(report)
local hit, found = 0, 0
for i, line in ipairs(lines) do
  if vim.startswith(line, 'SF:' .. root .. '/') then
    lines[i] = 'SF:' .. line:sub(#root + 5)
  elseif vim.startswith(line, 'LH:') then
    hit = hit + tonumber(line:sub(4))
  elseif vim.startswith(line, 'LF:') then
    found = found + tonumber(line:sub(4))
  end
end
vim.fn.writefile(lines, report)
print(
  ('coverage: %.1f%% of %d lines, report in %s'):format(
    found == 0 and 0 or hit * 100 / found,
    found,
    vim.fs.relpath(root, report) or report
  )
)
