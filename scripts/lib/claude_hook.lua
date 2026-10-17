-- The decisions behind the Claude Code hooks of this repository
-- (`.claude/settings.json`), kept apart from `scripts/claude-hook.lua`, which
-- only reads the event and prints the answer, so the specs can ask them
-- directly:
--
--   local hook = dofile(root .. '/scripts/lib/claude_hook.lua')
--
-- Before a tool runs, a command or a path that reaches a credential store, or
-- a command that applies chezmoi or skips a hook, is refused, and an edit of a
-- lockfile is put to the user. After an edit of a Lua file, the agent is told
-- about patterns AGENTS.md rules out that the edit added, and about StyLua
-- disagreeing with the file. None of this replaces the rules: it catches the
-- slips that happen anyway.

local M = {}

--- A path is a credential store when one of these matches it, the path
--- normalized and prefixed with `/` so a relative one matches too
M.SECRET_PATHS = {
  '/secrets/data/',
  '/secrets/data$',
  '%.age$',
  '/encrypted_[^/]*$',
  '/%.env$',
  '/%.env%.[^/]*$',
  '/%.envrc$',
  '/%.ssh/',
  '/%.gnupg/',
  '/%.aws/',
  '/%.kube/',
  '/%.netrc$',
}

--- Commands refused outright, each with why and what to do instead
---@type { [1]: string, [2]: string }[]
M.COMMANDS = {
  -- `[^;|&]-` lets flags sit between a command and its verb
  -- (`chezmoi -S . apply`) without reaching the next command of a pipeline
  {
    '%f[%w]chezmoi%f[%W][^;|&]-%f[%w]apply%f[%W]',
    'chezmoi apply writes over the real $HOME: show `chezmoi diff` and let the user apply',
  },
  {
    '%f[%w]chezmoi%f[%W][^;|&]-%f[%w]destroy%f[%W]',
    'chezmoi destroy deletes from the real $HOME: ask the user',
  },
  {
    '%f[%w]chezmoi%f[%W][^;|&]-%f[%w]forget%f[%W]',
    'chezmoi forget drops a file from the source: ask the user',
  },
  {
    '%-%-no%-verify',
    'the hooks exist to protect the user: fix what they report instead',
  },
  {
    -- `-n` is `--no-verify` to `git commit`, alone or among other short flags
    '%f[%w]commit%f[%W][^;|&]-%s%-%a*n%a*%f[%W]',
    '`git commit -n` skips the hooks, which exist to protect the user',
  },
  { 'chezmoi%-dycrypt', 'it decrypts secrets, which are off limits' },
  {
    '%f[%w]chezmoi%f[%W][^;|&]-%f[%w]decrypt%f[%W]',
    'it decrypts secrets, which are off limits',
  },
  { '%f[%w]age%s+%-d', 'it decrypts secrets, which are off limits' },
  { '%f[%w]age%s+%-%-decrypt', 'it decrypts secrets, which are off limits' },
  {
    '%f[%w]sops%f[%W][^;|&]-%s%-d%f[%W]',
    'it decrypts secrets, which are off limits',
  },
  {
    '%f[%w]sops%f[%W][^;|&]-%f[%w]decrypt%f[%W]',
    'it decrypts secrets, which are off limits',
  },
  {
    '%f[%w]gpg2?%f[%W][^;|&]-%s%-%-?d%a*%f[%W]',
    'it decrypts secrets, which are off limits',
  },
  { '%f[%w]pass%s+show%f[%W]', 'it reveals a secret, which is off limits' },
  { '%f[%w]op%s+read%f[%W]', 'it reveals a secret, which is off limits' },
  { '%f[%w]vault%s+read%f[%W]', 'it reveals a secret, which is off limits' },
}

--- The tools that change a file, and so need asking before a lockfile
M.WRITERS = { Edit = true, MultiEdit = true, Write = true, NotebookEdit = true }

--- A pattern AGENTS.md rules out in Lua code
---@class DyClaudeLuaRule
---@field pattern string
---@field reason string What to do instead, as the agent is told
---@field allow? string[] Paths, relative to the repository, whose job is to
--- use the pattern; `tests/` always may
---@field keep? table<string, true> Matches that are fine all the same

---@type DyClaudeLuaRule[]
M.LUA_RULES = {
  {
    pattern = 'vim%.keymap%.set%(',
    reason = 'a global mapping goes through `map` (util.plugin.safe_keymap_set); a buffer-local one may stay',
    allow = { 'lua/util/plugin.lua' },
  },
  {
    pattern = ':wait%(',
    reason = 'never block the main loop: `util.system.run`, or `util.system.sync` where a caller must wait',
    allow = { 'lua/util/system.lua', 'scripts/' },
  },
  {
    pattern = '_G%.[%a_][%w_]*',
    reason = 'no loose globals: a setting is a field of `DyNeo` in lua/config/globals.lua',
    allow = { 'lua/config/globals.lua' },
    keep = { ['_G.DyNeo'] = true, ['_G.dd'] = true, ['_G.Snacks'] = true },
  },
  {
    pattern = 'LazyVim',
    reason = 'LazyVim is gone: use `DyNeo.*` and lua/util/*',
  },
  {
    pattern = '[\'"]e!',
    reason = 'never reload over user edits with `:e!`: set the buffer up again',
  },
  {
    pattern = '[\'"]edit!',
    reason = 'never reload over user edits with `:edit!`: set the buffer up again',
  },
}

--- `path` normalized, with a leading `/` so the patterns can anchor on it
---@param path string
---@return string
local function anchored(path)
  path = vim.fs.normalize(path)
  return path:sub(1, 1) == '/' and path or '/' .. path
end

--- Whether `path` lies in a credential store
---@param path string?
---@return boolean
function M.is_secret_path(path)
  if not path or path == '' then return false end
  local p = anchored(path)
  for _, pattern in ipairs(M.SECRET_PATHS) do
    if p:find(pattern) then return true end
  end
  return false
end

--- Why `command` is refused, or nil
---@param command string?
---@return string?
function M.check_command(command)
  if not command then return nil end
  for _, rule in ipairs(M.COMMANDS) do
    if command:find(rule[1]) then return rule[2] end
  end
  for word in command:gmatch('[^%s;|&()<>\'"`=]+') do
    -- A glob that leaves secrets out (`--glob '!*.age'`) reaches none, and a
    -- word with neither a separator nor a dot is a search term, not a path
    if
      not word:find('[*!]')
      and word:find('[/.]')
      and M.is_secret_path(word)
    then
      return ('`%s` is a credential store, which is off limits'):format(word)
    end
  end
  return nil
end

--- The paths a tool call reads or writes
---@param input table
---@return string[]
local function paths_of(input)
  local paths = {}
  for _, key in ipairs({ 'file_path', 'notebook_path', 'path' }) do
    if type(input[key]) == 'string' then table.insert(paths, input[key]) end
  end
  -- Glob's `pattern` and Grep's `glob` reach files as well, unless they
  -- leave them out (`!*.age`)
  for _, key in ipairs({ 'pattern', 'glob' }) do
    local value = input[key]
    if type(value) == 'string' and value:sub(1, 1) ~= '!' then
      table.insert(paths, value)
    end
  end
  return paths
end

--- The answer to a `PreToolUse` event, or nil to let the call through
---@param event table
---@return table?
function M.pre_tool_use(event)
  local input = event.tool_input or {}
  local function answer(decision, reason)
    return {
      hookSpecificOutput = {
        hookEventName = 'PreToolUse',
        permissionDecision = decision,
        permissionDecisionReason = 'DyNeo: ' .. reason,
      },
    }
  end

  if event.tool_name == 'Bash' then
    local reason = M.check_command(input.command)
    return reason and answer('deny', reason) or nil
  end
  for _, path in ipairs(paths_of(input)) do
    if M.is_secret_path(path) then
      return answer(
        'deny',
        ('`%s` is a credential store, which is off limits'):format(path)
      )
    end
  end
  if not M.WRITERS[event.tool_name] then return nil end
  for _, path in ipairs(paths_of(input)) do
    if vim.fs.basename(path):find('^lazy%-lock.*%.json$') then
      return answer(
        'ask',
        'the lockfile changes on every `:Lazy update`; edit it only for a plugin task'
      )
    end
  end
  return nil
end

--- How many times `pattern` occurs in `text`, minus those `keep` allows
---@param text string?
---@param rule table
---@return integer
local function count(text, rule)
  local n = 0
  for match in (text or ''):gmatch(rule.pattern) do
    if not (rule.keep and rule.keep[match]) then n = n + 1 end
  end
  return n
end

--- Whether `path`, relative to `root`, starts with one of `prefixes`
---@param path string
---@param root string
---@param prefixes string[]?
---@return boolean
local function allowed(path, root, prefixes)
  local relative = path
  local prefix = vim.fs.normalize(root) .. '/'
  if vim.startswith(path, prefix) then relative = path:sub(#prefix + 1) end
  for _, allow in ipairs(prefixes or {}) do
    if vim.startswith(relative, allow) then return true end
  end
  return vim.startswith(relative, 'tests/')
end

--- The text an edit took out and the text it put in
---@param event table
---@return string before, string after
local function change(event)
  local input = event.tool_input or {}
  if event.tool_name == 'Write' then
    local response = event.tool_response or {}
    local original = type(response) == 'table' and response.originalFile
    return type(original) == 'string' and original or '', input.content or ''
  end
  local edits = input.edits or { input }
  local before, after = {}, {}
  for _, edit in ipairs(edits) do
    table.insert(before, edit.old_string or '')
    table.insert(after, edit.new_string or '')
  end
  return table.concat(before, '\n'), table.concat(after, '\n')
end

--- What an edit of a Lua file added that AGENTS.md rules out
---@param event table
---@param root string The repository the hook runs for
---@return string[]
function M.lua_findings(event, root)
  local path = vim.fs.normalize((event.tool_input or {}).file_path or '')
  if not path:find('%.lua$') then return {} end
  local before, after = change(event)
  local findings = {}
  for _, rule in ipairs(M.LUA_RULES) do
    if
      not allowed(path, root, rule.allow)
      and count(after, rule) > count(before, rule)
    then
      table.insert(findings, rule.reason)
    end
  end
  return findings
end

--- The answer to a `PostToolUse` event, or nil when there is nothing to say
---@param event table
---@param root string
---@param stylua? fun(path: string): string? What StyLua says against the
--- file, nil when it agrees
---@return table?
function M.post_tool_use(event, root, stylua)
  local path = (event.tool_input or {}).file_path
  if type(path) ~= 'string' or not path:find('%.lua$') then return nil end
  local lines = {}
  for _, finding in ipairs(M.lua_findings(event, root)) do
    table.insert(lines, '- ' .. finding)
  end
  local style = stylua and stylua(path)
  if style then table.insert(lines, '- ' .. style) end
  if #lines == 0 then return nil end
  return {
    decision = 'block',
    reason = ('DyNeo: the edit of %s needs another look:\n%s'):format(
      path,
      table.concat(lines, '\n')
    ),
  }
end

return M
