--- The luacov configuration the specs run under and the report is drawn
--- from, in one place so both read the same files and count the same
--- directories.
---
--- Stats and report live under `.tests/coverage/`, which git ignores. The
--- patterns match file names with the `.lua` dropped, as luacov hands them
--- over. Everything the specs mirror is counted; `lua/per_machine/`, rendered
--- by chezmoi and absent from a clone, is not.
---@class DyCoverage
---@field dir string Where the stats and the report are written
---@field sources string[] The directories counted, relative to the root
---@field luacov table The configuration `luacov.runner` takes

---@param root string The repository, an absolute normalized path
---@return DyCoverage
return function(root)
  local escaped = root:gsub('%p', '%%%0')
  local dir = vim.fs.joinpath(root, '.tests', 'coverage')
  local sources = { 'lua', 'plugin', 'ftplugin', 'ftdetect', 'after', 'lsp' }
  local include = {}
  for _, sub in ipairs(sources) do
    table.insert(include, '^' .. escaped .. '/' .. sub .. '/')
  end
  return {
    dir = dir,
    sources = sources,
    luacov = {
      statsfile = vim.fs.joinpath(dir, 'luacov.stats.out'),
      reportfile = vim.fs.joinpath(dir, 'lcov.info'),
      include = include,
      exclude = { '^' .. escaped .. '/lua/per_machine/' },
    },
  }
end
