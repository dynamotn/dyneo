-- Build the tree-sitter parsers named on the command line, for the specs that
-- need real ones: the language cases of `tests/spec/util/neogen_spec.lua`,
-- which fail on CI when their parser is missing.
--
-- nvim-treesitter builds with the tree-sitter CLI; one not on `$PATH` comes
-- from Mason, as `util.treesitter` gets it for the configuration. Run once the
-- plugins are installed, with `--clean` so that nothing else of the
-- configuration comes along:
--
--   nvim --clean --headless -l scripts/install-parsers.lua bash fish ...
--
-- Exits non-zero, and says why, when a parser could not be built.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local lazy = vim.fs.joinpath(vim.fn.stdpath('data') --[[@as string]], 'lazy')
vim.opt.runtimepath:prepend({
  root,
  vim.fs.joinpath(lazy, 'mason.nvim'),
  vim.fs.joinpath(lazy, 'nvim-treesitter'),
})
-- For `lua:dy-mason-registry`, which mason requires on refresh
local registry_plugin =
  dofile(root .. '/scripts/lib/mason_registry.lua').dir(root)
if registry_plugin then vim.opt.runtimepath:prepend(registry_plugin) end

local TIMEOUT = 10 * 60 * 1000

---@param message string
local function fail(message)
  io.stderr:write('install-parsers: ' .. message .. '\n')
  os.exit(1)
end

local langs = { unpack(arg) }
if #langs == 0 then fail('name the parsers to build') end

if vim.fn.executable('tree-sitter') == 0 then
  -- The registries `plugins.integration.tool_manager` sets: Mason keys the
  -- fetched index on the list, and would fetch again for a different one
  require('mason').setup({
    registries = {
      'lua:tools.mason-registry',
      'lua:dy-mason-registry',
      'github:mason-org/mason-registry',
    },
  })
  local registry = require('mason-registry')
  local done, ok = false, false
  registry.refresh(function()
    local found, package = pcall(registry.get_package, 'tree-sitter-cli')
    if not found then
      done = true
      return
    end
    package:install(nil, function(success)
      ok, done = success, true
    end)
  end)
  vim.wait(TIMEOUT, function() return done end)
  -- Mason puts its `bin` directory on `$PATH` on setup
  if not ok or vim.fn.executable('tree-sitter') == 0 then
    fail('could not install tree-sitter-cli with Mason')
  end
end

local built =
  require('nvim-treesitter').install(langs, { summary = true }):wait(TIMEOUT)
if not built then fail('could not build ' .. table.concat(langs, ', ')) end
