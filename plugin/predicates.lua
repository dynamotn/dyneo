-- The Tree-sitter predicates the queries of this configuration name:
-- `queries/yaml`, `after/queries/toml` and `after/queries/gotmpl`. They are
-- registered here, not by a language's plugin spec, because a query runs
-- whenever its parser does -- YAML injected into Markdown, a TOML buffer with
-- the `toml` language disabled -- and a predicate with no handler fails every
-- match of the query. The first `FileType` comes before any buffer is
-- highlighted, and waiting for it keeps `vim.treesitter.query` out of a start
-- that opens no file.

---@param source integer|string A buffer, or the text of a string parser
---@return integer
local function buffer(source) return tonumber(source) or 0 end

--- Asks what a buffer *is* rather than what it is called: `ftdetect` already
--- knows that `.github/workflows/ci.yml` is a workflow
---@param filetypes string[]
---@return fun(match: table, pattern: integer, source: integer|string): boolean
local function filetype_is(filetypes)
  return function(_, _, source)
    return vim.list_contains(filetypes, vim.bo[buffer(source)].filetype)
  end
end

--- Whether the file name of the buffer matches one of `patterns` whole
---@param patterns string[] Lua patterns
---@param when? fun(): boolean Checked first; the predicate is false without
---@return fun(match: table, pattern: integer, source: integer|string): boolean
local function name_is(patterns, when)
  return function(_, _, source)
    if when and not when() then return false end
    local name = vim.fs.basename(vim.api.nvim_buf_get_name(buffer(source)))
    for _, pattern in ipairs(patterns) do
      if name:match(pattern) == name then return true end
    end
    return false
  end
end

-- `chezmoi-template.nvim` injects the target language into every template,
-- asking chezmoi for it rather than guessing from the name, so the gotmpl
-- predicates below match nothing when it is in the spec: both at once would
-- parse each template twice. Asked once, on the first template.
local guess_by_name ---@type boolean?
local function without_chezmoi_plugin()
  if guess_by_name == nil then
    local ok, enabled = pcall(
      function() return require('util.chezmoi').enabled() end
    )
    guess_by_name = not (ok and enabled)
  end
  return guess_by_name
end

---@type table<string, fun(match: table, pattern: integer, source: integer|string): boolean>
local PREDICATES = {
  -- queries/yaml/injections.scm
  ['is-gh-action?'] = filetype_is({ 'yaml.gh-action' }),
  ['is-ci-pipeline?'] = filetype_is({ 'yaml.gitlab', 'yaml.az-pl' }),
  -- after/queries/toml/injections.scm
  ['is-mise?'] = name_is({ '.*mise.*%.toml$' }),
  -- after/queries/gotmpl/injections.scm: the target language of a template,
  -- told by its file name
  ['is-bash-file?'] = name_is(
    { '.*%.sh%.tmpl$', 'executable_.*%.tmpl$' },
    without_chezmoi_plugin
  ),
  ['is-fish-file?'] = name_is({ '.*%.fish%.tmpl$' }, without_chezmoi_plugin),
  ['is-yaml-file?'] = name_is({ '.*%.ya?ml%.tmpl$' }, without_chezmoi_plugin),
  ['is-toml-file?'] = name_is({ '.*%.toml%.tmpl$' }, without_chezmoi_plugin),
  ['is-ini-file?'] = name_is({ '.*%.ini%.tmpl$' }, without_chezmoi_plugin),
  ['is-js-file?'] = name_is({ '.*%.js%.tmpl$' }, without_chezmoi_plugin),
  ['is-python-file?'] = name_is({ '.*%.py%.tmpl$' }, without_chezmoi_plugin),
  ['is-lua-file?'] = name_is({ '.*%.lua%.tmpl$' }, without_chezmoi_plugin),
}

vim.api.nvim_create_autocmd('FileType', {
  group = vim.api.nvim_create_augroup('dy_predicates', { clear = true }),
  once = true,
  callback = function()
    local query = require('vim.treesitter.query')
    for name, handler in pairs(PREDICATES) do
      query.add_predicate(name, handler, { force = true, all = false })
    end
  end,
})
