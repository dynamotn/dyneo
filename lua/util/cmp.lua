local Plugin = require('util.plugin')

local M = {}

--- Setup default sources of cmp
M.setup_default_sources = function()
  local success, node = pcall(vim.treesitter.get_node)
  if
    success
    and node
    and vim.tbl_contains(
      { 'comment', 'line_comment', 'block_comment' },
      node:type()
    )
  then
    return M.sources('comment')
  else
    return M.sources('*')
  end
end

--- Sources for filetype
---@param filetype string Filetype to enable sources. `*` for undefined
M.sources = function(filetype)
  local common_sources = {
    'lsp',
    'path',
    'project_path',
    'fuzzy_path',
    'snippets',
    'buffer',
    'calc',
    'emoji',
    'dynamic',
    'dictionary',
  }
  -- The pane sources say themselves whether their server is there
  vim.list_extend(common_sources, { 'tmux', 'zellij', 'kitty' })
  local unique_sources = {
    markdown = { 'nerdfont' },
    typst = { 'nerdfont' },
    blade = { 'blade-nav', 'laravel' },
    clojure = { 'conjure' },
    fish = { 'fish' },
    julia = { 'latex_symbols' },
    sql = { 'dadbod', 'sql' },
    lua = { 'lazydev' },
  }

  if filetype == 'comment' then
    return { 'buffer', 'dictionary', 'emoji', 'nerdfont', 'dynamic' }
  elseif filetype == 'dap' then
    return { 'dap', 'buffer' }
  elseif vim.list_contains({ 'gitcommit', 'gitrebase', 'octo' }, filetype) then
    return {
      'git',
      'lsp',
      'snippets',
      'buffer',
      'emoji',
      'nerdfont',
      'dynamic',
      'dictionary',
    }
  elseif vim.list_contains(vim.tbl_keys(unique_sources), filetype) then
    local result = {}
    vim.list_extend(result, unique_sources[filetype])
    return vim.list_extend(result, common_sources)
  elseif filetype == '*' then
    return common_sources
  end
end

---@alias BlinkAction fun(): boolean?

--- Named actions for completion keys, filled in by the snippet and AI
--- plugins as they load. An action returns true when it handled the key.
---@type table<string, BlinkAction>
M.actions = {
  snippet_forward = function()
    if vim.snippet.active({ direction = 1 }) then
      vim.schedule(function() vim.snippet.jump(1) end)
      return true
    end
  end,
  snippet_stop = function()
    if vim.snippet then vim.snippet.stop() end
  end,
}

--- Key handler running `actions` in turn until one handles the key, then
--- `fallback`
---@param actions string[]
---@param fallback? string|fun()
function M.map(actions, fallback)
  return function()
    for _, name in ipairs(actions) do
      if M.actions[name] and M.actions[name]() then return true end
    end
    return type(fallback) == 'function' and fallback() or fallback
  end
end

--- Whether blink's own `cmdline` source completes a path at the cursor: the
--- argument of `:edit`, `:cd`, `:find`, a `complete=file` command, `:!./`.
--- It then lists the entries of the directory typed so far, which is just
--- what `path` would list a second time.
---@return boolean
function M.cmdline_completes_path()
  local ok, utils = pcall(require, 'blink.cmp.sources.cmdline.utils')
  if not ok then return false end
  return utils.is_path_completion(
    utils.get_completion_type('cmdline'),
    vim.fn.getcmdline()
  )
end

--- Sources of the command line: the `cmdline` source, then paths and the
--- words of the buffers; `path` only where `cmdline` does not complete paths
--- itself. `fuzzy_path` stays either way: it finds files anywhere below,
--- under their whole relative path.
---@return string[]
function M.cmdline_sources()
  local type = vim.fn.getcmdtype()
  -- Search forward and backward
  if type == '/' or type == '?' then return { 'buffer' } end
  -- Commands, and `input()` that may complete like one
  if type == ':' or type == '@' then
    if M.cmdline_completes_path() then
      return { 'cmdline', 'fuzzy_path', 'buffer' }
    end
    return { 'cmdline', 'fuzzy_path', 'path', 'buffer' }
  end
  return {}
end

return M
