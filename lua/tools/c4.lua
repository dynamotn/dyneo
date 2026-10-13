--- A LikeC4 view, drawn in the editor
---
--- `likec4 gen d2` writes every view of a workspace as D2, one file a view;
--- `:DyC4 [{view}]` runs it on the workspace of the buffer, into a cache of
--- its own, and hands the view asked for -- or picked, when there are
--- several -- to the D2 preview of `tools.diagram.d2.snacks`. Nothing is
--- written into the workspace.
local M = {}

local notify = require('util.notify').titled('C4')

--- Milliseconds the generation may take: it reads the whole workspace
M.TIMEOUT = 120 * 1000

--- The configs a workspace may have, as `@likec4/lsp` names them
M.JSON_CONFIGS = { '.likec4rc', '.likec4.config.json', 'likec4.config.json' }

--- The configs likec4 loads by running them, as the user
M.CODE_CONFIGS = {
  'likec4.config.js',
  'likec4.config.cjs',
  'likec4.config.mjs',
  'likec4.config.ts',
  'likec4.config.cts',
  'likec4.config.mts',
}

--- What marks the root of a workspace: the nearest config of any name,
--- else the repository
M.ROOT_MARKERS = {
  vim.list_extend(vim.deepcopy(M.JSON_CONFIGS), M.CODE_CONFIGS),
  '.git',
}

--- Entries walked under a root before it is taken to hold a code config:
--- an unread rest must not be a clean result
M.SCAN_LIMIT = 20000

---@type table<string, string|false>
local code_config_of = {}

--- The first code config under `root` that likec4 would run, as it walks:
--- no hidden entry, no `node_modules` nor `out`. False when there is none.
---@param root string
---@return string|false
function M.code_config(root)
  if code_config_of[root] ~= nil then return code_config_of[root] end
  local found, seen = false, 0
  for name, kind in
    vim.fs.dir(root, {
      depth = math.huge,
      skip = function(dir)
        local base = vim.fs.basename(dir)
        return not vim.startswith(base, '.')
          and base ~= 'node_modules'
          and base ~= 'out'
      end,
    })
  do
    seen = seen + 1
    if seen > M.SCAN_LIMIT then
      found = 'any likec4.config.* among its files'
      break
    end
    if
      kind == 'file'
      and vim.list_contains(M.CODE_CONFIGS, vim.fs.basename(name))
    then
      found = name
      break
    end
  end
  code_config_of[root] = found
  return found
end

--- Whether `root` may run the code config it holds, if any, asked once;
--- `sticky` keeps a refusal for the session, as a server start does
---@param purpose string
---@param root string
---@param action string What runs it: `Start the LikeC4 server`
---@param sticky? boolean
---@return boolean
function M.trusted(purpose, root, action, sticky)
  local config = M.code_config(root)
  if not config then return true end
  local question = ('%s in %s?\nIt runs %s as you.'):format(
    action,
    vim.fn.fnamemodify(root, ':~'),
    config
  )
  return require('util.trust').ask(purpose, root, question, sticky)
end

--- What likec4 says went wrong in `stderr`, colours removed: each `ERR`
--- message with its indented lines, at most `max` lines in all
---@param stderr string
---@param max? integer
---@return string[]
function M.errors(stderr, max)
  max = max or 5
  local lines, inside = {}, false
  for line in vim.gsplit(stderr:gsub('\27%[[%d;]*m', ''), '\n') do
    if #lines >= max then break end
    local message = line:match('%f[%w]ERR%s+(.-)%s*$')
    if message then
      table.insert(lines, message)
      inside = true
    elseif inside and line:match('^%s+%S') then
      table.insert(lines, vim.trim(line))
    else
      inside = false
    end
  end
  return lines
end

--- The one line that says why likec4 failed: its first `ERR`, else its
--- `error:`, else the first line; never its usage
---@param result table As `util.system.run` answers
---@return string
local function failure(result)
  local stderr = (result.stderr or ''):gsub('\27%[[%d;]*m', '')
  local line = M.errors(stderr, 1)[1]
    or stderr:match('\nerror:%s*([^\n]-)%s*\n')
    or stderr:match('^%s*([^\n]-)%s*\n')
  if result.missing or result.timed_out or not line or line == '' then
    return require('util.system').failure(result, 'likec4')
  end
  return line
end

--- Where the views of the workspace at `root` are written
---@param root string
---@return string
function M.out_dir(root)
  return vim.fs.joinpath(
    vim.fn.stdpath('cache') --[[@as string]],
    'dyneo-c4',
    vim.fn.sha256(root):sub(1, 16)
  )
end

--- The views `likec4 gen d2` wrote under `dir`, by name
---@param dir string
---@return table<string, string> files
---@return string[] names Sorted
function M.views(dir)
  local files, names = {}, {}
  for _, file in
    ipairs(vim.fs.find(function(name) return name:match('%.d2$') ~= nil end, {
      path = dir,
      type = 'file',
      limit = math.huge,
    }))
  do
    local name = vim.fs.basename(file):gsub('%.d2$', '')
    if not files[name] then table.insert(names, name) end
    files[name] = file
  end
  table.sort(names)
  return files, names
end

--- Preview `file` with the D2 renderer
---@param file string
local function preview(file)
  require('tools.diagram.d2.snacks').preview(vim.fn.bufadd(file))
end

--- Draw `view` of the workspace of the current buffer, or one picked
---@param view? string
function M.show(view)
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].modified then
    return notify(
      'Write the buffer first: likec4 reads the files on disk',
      vim.log.levels.WARN
    )
  end
  local root = vim.fs.root(bufnr, M.ROOT_MARKERS)
  if not root then
    return notify('This buffer is in no LikeC4 workspace', vim.log.levels.WARN)
  end
  if not M.trusted('c4', root, 'Draw the LikeC4 views') then
    return notify(
      'Not drawn: the workspace is not trusted to run its config',
      vim.log.levels.WARN
    )
  end
  local out = M.out_dir(root)
  -- Views since removed must not linger: the directory is this tool's alone
  vim.fn.delete(out, 'rf')
  vim.fn.mkdir(out, 'p')
  local system = require('util.system')
  system.run(
    { 'likec4', 'gen', 'd2', root, '-o', out },
    -- Merged into the environment; chalk heeds FORCE_COLOR over NO_COLOR
    {
      cwd = root,
      timeout = M.TIMEOUT,
      env = { NO_COLOR = '1', FORCE_COLOR = '0' },
    },
    function(result)
      local files, names = M.views(out)
      if result.code ~= 0 or result.cut or #names == 0 then
        return notify(
          'likec4 gen d2 failed: '
            .. (
              #names == 0 and result.code == 0 and 'no view in the workspace'
              or failure(result)
            ),
          vim.log.levels.ERROR
        )
      end
      -- It still exits 0 and writes what it could of a broken model
      local errors = M.errors(result.stderr)
      if #errors > 0 then
        return notify(
          'The model has errors, not drawn:\n' .. table.concat(errors, '\n'),
          vim.log.levels.ERROR
        )
      end
      if view then
        if not files[view] then
          return notify(
            ('No view %s: %s'):format(view, table.concat(names, ', ')),
            vim.log.levels.WARN
          )
        end
        return preview(files[view])
      end
      if #names == 1 then return preview(files[names[1]]) end
      vim.ui.select(names, { prompt = 'View' }, function(choice)
        if choice then preview(files[choice]) end
      end)
    end
  )
end

--- The mapping of a LikeC4 buffer
---@param bufnr integer
function M.attach(bufnr)
  vim.keymap.set(
    'n',
    '<localleader>p',
    function() M.show() end,
    { buffer = bufnr, desc = 'Preview View (LikeC4)' }
  )
end

return M
