--- `:DyAi`: prompts sent with the code they are about, and one picker over
--- every AI action of the configuration
---
--- A prompt goes to `DyNeo.ai.target`, Avante or the CLI in sidekick. Both
--- are wrapped by `util.ai_guard`, and the buffer is checked here as well
--- before its text is put into a prompt, since what is sent is that text
--- rather than the buffer itself.
local M = {}

--- Subcommands other than the names of prompts
M.SUBCOMMANDS = { 'pick', 'prompts', 'commit', 'staged', 'pr', 'ci', 'model' }

local notify = require('util.notify').titled('AI')

--- Log a handover of `what`, a buffer or a path
---@param action 'sent'|'refused'
---@param what integer|string
---@param detail? string
local function record(action, what, detail)
  local audit = require('util.ai_audit')
  if type(what) == 'number' then
    audit.record_buffer('dyai', action, what, detail)
  else
    audit.record('dyai', action, what, detail)
  end
end

--- Hand `text` to the AI of `DyNeo.ai.target`
---
--- `what` is the buffer or the path the text was taken from: it decides
--- whether the project keeps AI local (`util.ai_policy`), and it is what the
--- audit log names. Whatever it holds has been checked already.
---@param text string
---@param what integer|string
---@param detail? string What was taken, for the audit log
---@return boolean sent
function M.deliver(text, what, detail)
  local target = DyNeo.ai and DyNeo.ai.target or 'avante'
  local policy = require('util.ai_policy')
  local reason = policy.local_only(what)
  if reason then
    -- The CLIs of sidekick answer from a service, never from this machine
    local provider = target == 'avante' and require('avante.config').provider
      or ''
    if not policy.is_local_provider(provider) then
      record('refused', what, detail)
      notify(
        ('%s: switch Avante to %s (:AvanteSwitchProvider)'):format(
          reason,
          table.concat((DyNeo.ai or {}).local_providers or {}, ' or ')
        ),
        vim.log.levels.WARN
      )
      return false
    end
  end
  if target == 'sidekick' then
    local lines = vim.tbl_map(
      function(line) return { { line } } end,
      vim.split(text, '\n', { plain = true })
    )
    -- `text` rather than `msg`, which sidekick would read as a template
    require('sidekick.cli').send({ text = lines, submit = true })
  elseif target == 'avante' then
    -- The prompt carries the code itself, so Avante's own copy of the
    -- selection is left out
    require('avante.api').ask({ question = text, without_selection = true })
  else
    notify(
      ('DyNeo.ai.target is %q, not avante or sidekick'):format(target),
      vim.log.levels.ERROR
    )
    return false
  end
  record('sent', what, detail)
  return true
end

--- Hand `text` to the AI of `DyNeo.ai.target`, unless `bufnr`, the buffer
--- it was taken from, is kept from AI
---@param text string
---@param bufnr integer
---@param detail? string What was taken, for the audit log
---@return boolean sent
function M.send(text, bufnr, detail)
  local sensitive = require('util.sensitive')
  if sensitive.is_sensitive(bufnr) then
    record('refused', bufnr, detail)
    notify(
      'Kept from AI: '
        .. table.concat(sensitive.reasons(bufnr), '; ')
        .. '. See :DyAiGuardCheck.',
      vim.log.levels.WARN
    )
    return false
  end
  return M.deliver(text, bufnr, detail)
end

--- Bytes of answer kept from a headless command
M.MAX_ANSWER = 64 * 1024

--- Have the command of `util.ai_policy` -- `DyNeo.ai.commit_command`, or
--- `local_command` where AI stays local -- write from `text` in `root`, and
--- hand `on_done` its answer
---@param text string
---@param root string
---@param label string What is being written, for the log and the notices
---@param on_done fun(answer: string)
function M.headless(text, root, label, on_done)
  local cmd, why = require('util.ai_policy').command(root)
  if not cmd then
    record('refused', root, label)
    return notify(why --[[@as string]], vim.log.levels.WARN)
  end
  -- The diff was checked on its way in; the commits, the branch name and
  -- whatever else the prompt took in are checked here, as the text goes out
  require('tools.ai.check').text(root, {}, text, function(reason)
    if reason then
      record('refused', root, label)
      return notify('Kept from AI: ' .. reason, vim.log.levels.WARN)
    end
    local system = require('util.system')
    notify(('Writing the %s with %s...'):format(label, cmd[1]))
    system.run(cmd, {
      cwd = root,
      stdin = text,
      timeout = (DyNeo.ai or {}).commit_timeout,
      max_bytes = M.MAX_ANSWER,
      -- A CLI that wants to ask something must not take over the terminal
      detach = true,
    }, function(result)
      local failed = result.code ~= 0 or result.cut
      -- Logged once it ran: a command that never started was handed nothing
      if not result.missing then
        record('sent', root, failed and (label .. ' (failed)') or label)
      end
      -- A cut answer is not a shorter message: it is a broken one
      if failed then
        return notify(system.failure(result, cmd[1]), vim.log.levels.ERROR)
      end
      if vim.trim(result.stdout) == '' then
        return notify(cmd[1] .. ' gave an empty answer', vim.log.levels.WARN)
      end
      on_done(result.stdout)
    end)
  end)
end

--- Expand prompt `name` for the current buffer and send it
---@param name string
---@param range? integer[] First and last line of the selection
---@return boolean found
function M.run(name, range)
  local prompts = require('tools.ai.prompts')
  local prompt = prompts.get(name)
  if not prompt then
    notify(('No prompt named %q'):format(name), vim.log.levels.WARN)
    return false
  end
  ---@type DyAiContext
  local ctx = { bufnr = vim.api.nvim_get_current_buf(), range = range }
  local function go()
    local text, cut = prompts.expand(prompt, ctx)
    if cut then
      notify(
        ('The code was cut at %d KiB'):format(prompts.MAX_BYTES / 1024),
        vim.log.levels.WARN
      )
    end
    local detail = prompt.name
      .. (range and (' %d-%d'):format(range[1], range[2]) or '')
    M.send(text, ctx.bufnr, detail)
  end
  if not prompts.wants_input(prompt) then
    go()
    return true
  end
  vim.ui.input({ prompt = prompt.description .. ': ' }, function(input)
    if not input or input == '' then return end
    ctx.input = input
    go()
  end)
  return true
end

--- Pick a model for Avante's current provider. An ACP agent lists its models
--- only once the sidebar has connected to it, so the sidebar is opened first
--- and the list waited for.
function M.avante_model()
  local config = require('avante.config')
  -- `:AvanteModels` only knows Avante's own providers, and fails on an ACP
  -- one such as the default `claude-code`
  if not config.acp_providers[config.provider] then
    vim.cmd.AvanteModels()
    return
  end
  local avante = require('avante')
  if not avante.is_sidebar_open() then avante.open_sidebar({}) end
  local tries = 150
  local function try()
    local sidebar = avante.get(false)
    local client = sidebar and sidebar.acp_client
    local session = sidebar
      and sidebar.chat_history
      and sidebar.chat_history.acp_session_id
    if client and client.config_options and session then
      require('avante.api').select_acp_model()
    elseif client and session and client:is_ready() then
      -- Connected, with no choice to offer: waiting longer changes nothing
      notify('The ACP agent offers no model to pick', vim.log.levels.WARN)
    elseif tries > 0 then
      tries = tries - 1
      vim.defer_fn(try, 100)
    else
      notify('The ACP agent did not connect', vim.log.levels.WARN)
    end
  end
  try()
end

--- States of Avante's sidebar while a request is under way
M.BUSY_STATES = {
  generating = true,
  thinking = true,
  ['tool calling'] = true,
  searching = true,
  compacting = true,
}

--- Avante's provider and model, and whether the sidebar of this tab is busy,
--- for the statusline. Nil until Avante has loaded; only tables are read, so
--- it is cheap enough for every redraw.
---@return string? text `provider` or `provider/model`
---@return boolean busy
function M.status()
  local config = package.loaded['avante.config']
  if not config or not config.provider then return nil, false end
  local provider = config.provider
  local settings = (config.providers or {})[provider]
  -- An ACP agent picks its model itself, once connected
  local model = not (config.acp_providers or {})[provider]
    and type(settings) == 'table'
    and settings.model
  local avante = package.loaded['avante']
  local sidebar = avante
    and avante.sidebars
    and avante.sidebars[vim.api.nvim_get_current_tabpage()]
  local busy = sidebar ~= nil and M.BUSY_STATES[sidebar.current_state] == true
  return model and (provider .. '/' .. model) or provider, busy
end

---@class DyAiAction
---@field group string
---@field name string
---@field key? string Mapping that does the same, shown beside it
---@field plugin? string The plugin it needs; left out where it is not set up
---@field run fun()

--- The actions of the picker other than the prompts
---@type DyAiAction[]
M.ACTIONS = {
  {
    group = 'Avante',
    name = 'Toggle chat',
    plugin = 'avante.nvim',
    key = '<leader>avc',
    run = function() require('avante').toggle() end,
  },
  {
    group = 'Avante',
    name = 'New chat',
    plugin = 'avante.nvim',
    key = '<leader>avC',
    run = function() vim.cmd.AvanteChatNew() end,
  },
  {
    group = 'Avante',
    name = 'Select model',
    plugin = 'avante.nvim',
    key = '<leader>avm',
    run = function() M.avante_model() end,
  },
  {
    group = 'Avante',
    name = 'Switch provider',
    plugin = 'avante.nvim',
    key = '<leader>avP',
    run = function() vim.cmd.AvanteSwitchProvider() end,
  },
  {
    group = 'Avante',
    name = 'History',
    plugin = 'avante.nvim',
    key = '<leader>avh',
    run = function() vim.cmd.AvanteHistory() end,
  },
  {
    group = 'Sidekick',
    name = 'Toggle CLI',
    plugin = 'sidekick.nvim',
    key = '<leader>aa',
    run = function() require('sidekick.cli').toggle() end,
  },
  {
    group = 'Sidekick',
    name = 'Select CLI',
    plugin = 'sidekick.nvim',
    key = '<leader>as',
    run = function() require('sidekick.cli').select() end,
  },
  {
    group = 'Claude',
    name = 'Toggle Claude Code',
    plugin = 'claudecode.nvim',
    key = '<leader>acc',
    run = function() vim.cmd.ClaudeCode() end,
  },
  {
    group = 'Claude',
    name = 'Continue Claude Code',
    plugin = 'claudecode.nvim',
    key = '<leader>acC',
    run = function() vim.cmd('ClaudeCode --continue') end,
  },
  {
    group = 'MCP',
    name = 'MCP Hub',
    plugin = 'mcphub.nvim',
    key = '<leader>M',
    run = function() vim.cmd.MCPHub() end,
  },
  {
    group = 'Git',
    name = 'Write commit message',
    key = '<localleader>g',
    run = function() require('tools.ai.commit').write() end,
  },
  {
    group = 'Git',
    name = 'Review staged changes',
    key = '<leader>ag',
    run = function() require('tools.ai.review').staged() end,
  },
  {
    group = 'Git',
    name = 'Describe the branch for its pull request',
    key = '<leader>aG',
    run = function() require('tools.ai.pr').describe() end,
  },
  {
    group = 'CI',
    name = 'Explain the failed job',
    key = '<localleader>e',
    run = function() require('tools.ai.ci').explain() end,
  },
  {
    group = 'Guard',
    name = 'Why is this buffer kept from AI',
    key = '<leader>ka',
    run = function() vim.cmd.DyAiGuardCheck() end,
  },
  {
    group = 'Guard',
    name = 'Handover log',
    key = '<leader>kL',
    run = function() vim.cmd.DyAiGuardLog() end,
  },
}

--- Picker items of every prompt, then of `M.ACTIONS` unless `prompts_only`
---@param range? integer[]
---@param prompts_only? boolean
---@return table[]
function M.items(range, prompts_only)
  local items = {}
  for _, prompt in ipairs(require('tools.ai.prompts').list()) do
    table.insert(items, {
      text = prompt.name .. ' ' .. prompt.description,
      group = prompt.project and 'Project' or 'Prompt',
      name = prompt.name,
      detail = prompt.description,
      preview = { text = prompt.body, ft = 'markdown' },
      run = function() M.run(prompt.name, range) end,
    })
  end
  if prompts_only then return items end
  local Plugin = require('util.plugin')
  for _, action in ipairs(M.ACTIONS) do
    if not action.plugin or Plugin.has(action.plugin) then
      table.insert(items, {
        text = action.group .. ' ' .. action.name,
        group = action.group,
        name = action.name,
        detail = action.key or '',
        preview = {
          text = ('# %s\n\n%s'):format(action.name, action.key or ''),
        },
        run = action.run,
      })
    end
  end
  return items
end

--- Every AI action in one picker; a prompt is sent with `range`
---@param range? integer[]
---@param prompts_only? boolean
function M.pick(range, prompts_only)
  local items = M.items(range, prompts_only)
  local width = 0
  for _, item in ipairs(items) do
    width = math.max(width, vim.api.nvim_strwidth(item.group))
  end
  Snacks.picker.pick({
    title = prompts_only and 'AI Prompts' or 'AI',
    items = items,
    format = function(item)
      return {
        {
          item.group .. (' '):rep(width - vim.api.nvim_strwidth(item.group)),
          'SnacksPickerComment',
        },
        { '  ' },
        { item.name, 'SnacksPickerLabel' },
        { '  ' },
        { item.detail, 'SnacksPickerComment' },
      }
    end,
    preview = 'preview',
    confirm = function(picker, item)
      picker:close()
      -- Once the picker is gone, so a prompt reads the buffer it came from
      if item then vim.schedule(item.run) end
    end,
  })
end

--- Handle `:DyAi`
---@param args { fargs: string[], range: integer, line1: integer, line2: integer }
function M.command(args)
  local range = args.range > 0 and { args.line1, args.line2 } or nil
  local sub = args.fargs[1]
  if not sub or sub == 'pick' then
    M.pick(range)
  elseif sub == 'prompts' then
    M.pick(range, true)
  elseif sub == 'commit' then
    require('tools.ai.commit').write()
  elseif sub == 'staged' then
    require('tools.ai.review').staged()
  elseif sub == 'pr' then
    require('tools.ai.pr').describe(args.fargs[2])
  elseif sub == 'ci' then
    require('tools.ai.ci').explain()
  elseif sub == 'model' then
    M.avante_model()
  else
    M.run(sub, range)
  end
end

--- Completion of `:DyAi`: the subcommands, then every prompt's name
---@param lead string
---@param line? string The command line so far
---@return string[]
function M.complete(lead, line)
  -- Only the first word is completed: `pr` takes a branch, typed
  if line and line:match('^%S+%s+%S+%s') then return {} end
  local words = vim.deepcopy(M.SUBCOMMANDS)
  for _, prompt in ipairs(require('tools.ai.prompts').list()) do
    table.insert(words, prompt.name)
  end
  return vim.tbl_filter(
    function(word) return word:find(lead, 1, true) == 1 end,
    words
  )
end

return M
