-- The Claude Code hooks of this repository, wired in `.claude/settings.json`:
--
--   nvim --clean --headless -l scripts/claude-hook.lua pre    # PreToolUse
--   nvim --clean --headless -l scripts/claude-hook.lua post   # PostToolUse
--
-- The event comes as JSON on stdin and the answer, if any, goes to stdout as
-- the JSON Claude Code reads. What is decided lives in
-- `scripts/lib/claude_hook.lua`.

local root = vim.fn.fnamemodify(debug.getinfo(1, 'S').source:sub(2), ':p:h:h')
local hook = dofile(root .. '/scripts/lib/claude_hook.lua')
local project = vim.env.CLAUDE_PROJECT_DIR or root

--- What StyLua says against `path`, nil when it has nothing to say
---@param path string
---@return string?
local function stylua(path)
  if vim.fn.executable('stylua') == 0 then
    return 'stylua is not on $PATH, so the style of the file is unchecked'
  end
  local ok, result = pcall(
    function()
      return vim
        .system({ 'stylua', '--check', path }, { cwd = project, text = true })
        :wait(5000)
    end
  )
  if not ok or not result or result.signal ~= 0 then
    return 'stylua did not answer in time, so the style of the file is unchecked'
  end
  if result.code ~= 0 then
    return ('StyLua disagrees with the file: run `stylua %s`'):format(path)
  end
  return nil
end

local phase = _G.arg[1]
local ok, answer = pcall(function()
  local event = vim.json.decode(io.stdin:read('a'))
  if phase == 'pre' then return hook.pre_tool_use(event) end
  if phase == 'post' then return hook.post_tool_use(event, project, stylua) end
  error('unknown phase ' .. tostring(phase))
end)

if not ok then
  local err = tostring(answer)
  io.stderr:write('claude-hook: ' .. err .. '\n')
  -- A guard that cannot decide refuses rather than letting the call through
  answer = phase == 'pre'
      and {
        hookSpecificOutput = {
          hookEventName = 'PreToolUse',
          permissionDecision = 'deny',
          permissionDecisionReason = 'DyNeo: the hook failed: ' .. err,
        },
      }
    or nil
end
if answer then io.stdout:write(vim.json.encode(answer) .. '\n') end
