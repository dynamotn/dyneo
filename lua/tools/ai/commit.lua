--- A commit message written by an AI from the staged diff
---
--- A `gitcommit` buffer is always kept from AI: `git commit --verbose` puts
--- the whole diff in it, sensitive files and all. So the buffer is never
--- read. The diff is taken from git, and only goes out once no staged path is
--- sensitive and neither `config.sensitive`'s patterns nor `betterleaks`
--- find a secret in it. A check that cannot run refuses, as a finding would.
---
--- The message is written into the buffer only where nothing has been typed
--- yet; a message already there is replaced only once the user says so.
local M = {}

--- Subjects of recent commits given as examples of the repository's style
M.HISTORY = 10

--- File name of the prompt, under `prompts/` of this configuration or of the
--- project's trusted `.nvim` folder
M.PROMPT = 'git/commit.md'

local notify = require('util.notify').titled('AI commit')

--- The prompt for `diff`, written in the style of `subjects`
---@param prompt DyAiPrompt
---@param ctx { diff: string, cut: boolean, paths: string[], subjects: string[], conventional: boolean }
---@return string
function M.build(prompt, ctx)
  local values = {
    files = table.concat(ctx.paths, '\n'),
    history = #ctx.subjects > 0 and table.concat(ctx.subjects, '\n')
      or '(no commits yet)',
    convention = ctx.conventional
        and 'The repository enforces Conventional Commits: `type(scope): subject`.'
      or 'Follow the style of the recent subjects.',
    diff = ctx.diff .. (ctx.cut and ('\n(diff cut at %d KiB)'):format(
      require('tools.ai.git').MAX_DIFF / 1024
    ) or ''),
    -- Longer than any backticks of the diff, which a Markdown change has
    fence = require('tools.ai.prompts').fence(ctx.diff),
  }
  return (prompt.body:gsub('{(%a+)}', values))
end

--- The message an AI answered, without the fence it may have wrapped it in
---@param reply string
---@return string[]
function M.message(reply)
  local lines = vim.split(vim.trim(reply), '\n', { plain = true })
  if lines[1] and lines[1]:match('^```') and lines[#lines] == '```' then
    lines = vim.list_slice(lines, 2, #lines - 1)
  end
  return lines
end

--- Lines git writes into the message file itself, after the comment prefix:
--- how the prefix is found when git picks it (`core.commentChar = auto`)
M.GIT_LINES = {
  '%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%-%- >8 ',
  'Please enter the commit message',
  'Changes to be committed:',
  'On branch ',
}

--- The comment prefix of `bufnr`'s message, from `value` of
--- `core.commentString` (or `core.commentChar`), else from the lines git
--- wrote with it, else `#`
---@param bufnr integer
---@param value? string
---@return string
function M.prefix(bufnr, value)
  if value and value ~= '' and value ~= 'auto' then return value end
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)) do
    for _, pattern in ipairs(M.GIT_LINES) do
      local prefix = line:match('^(%S+) ' .. pattern)
      if prefix then return prefix end
    end
  end
  return '#'
end

--- Hand `on_done` the comment prefix of the commit message in `bufnr`
---@param root string
---@param bufnr integer
---@param on_done fun(prefix: string)
function M.comment(root, bufnr, on_done)
  -- Two names of one setting: the one set last wins, as in git
  require('util.system').run({
    'git',
    'config',
    '--get-regexp',
    [[^core\.comment(char|string)$]],
  }, { cwd = root, timeout = 5000 }, function(result)
    -- The message may be written and its buffer gone by now
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    local value
    for line in (result.stdout or ''):gmatch('[^\n]+') do
      value = line:match('^%S+ (.*)$') or value
    end
    on_done(M.prefix(bufnr, value))
  end)
end

--- Lines before the first comment: what the user has typed of the message
---@param bufnr integer
---@param prefix string What a comment line starts with
---@return integer last Line where the message area ends, 0-based, exclusive
---@return boolean empty
local function message_area(bufnr, prefix)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local last, empty = #lines, true
  for i, line in ipairs(lines) do
    if vim.startswith(line, prefix) then
      last = i - 1
      break
    end
    if vim.trim(line) ~= '' then empty = false end
  end
  return last, empty
end

--- Put `lines` in the message area of `bufnr`, asking first when the user
--- has written something there already
---@param bufnr integer
---@param lines string[]
---@param prefix? string What a comment line starts with, `#` unless given
function M.insert(bufnr, lines, prefix)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  prefix = prefix or '#'
  local _, empty = message_area(bufnr, prefix)
  local function put()
    -- The buffer may have changed while the question was up
    local last = message_area(bufnr, prefix)
    vim.api.nvim_buf_set_lines(
      bufnr,
      0,
      last,
      false,
      vim.list_extend(vim.deepcopy(lines), { '' })
    )
  end
  if empty then
    put()
    return
  end
  vim.ui.select(
    { 'Replace it', 'Keep mine' },
    { prompt = 'A message is written already' },
    function(choice)
      if choice == 'Replace it' and vim.api.nvim_buf_is_valid(bufnr) then
        put()
      end
    end
  )
end

--- Write the message of the commit being edited in the current buffer
function M.write()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.bo[bufnr].filetype ~= 'gitcommit' then
    notify('Run it in a commit message (git commit)', vim.log.levels.WARN)
    return
  end
  local prompt = require('tools.ai.prompts').template(M.PROMPT)
  if not prompt then
    notify('No prompt ' .. M.PROMPT, vim.log.levels.ERROR)
    return
  end
  local git = require('tools.ai.git')
  local function fail(reason, where)
    require('util.ai_audit').record(
      'dyai',
      'refused',
      where or vim.api.nvim_buf_get_name(bufnr),
      'commit'
    )
    notify(reason, vim.log.levels.WARN)
  end
  git.root(bufnr, function(root, err)
    if not root then
      return fail(err --[[@as string]])
    end
    git.change(root, nil, function(change, why)
      if not change then
        return fail(why --[[@as string]], root)
      end
      git.log(root, { '-' .. M.HISTORY, '--format=%s' }, function(subjects)
        if change.cut then
          notify(
            ('The diff was cut at %d KiB'):format(git.MAX_DIFF / 1024),
            vim.log.levels.WARN
          )
        end
        local text = M.build(prompt, {
          diff = change.diff,
          cut = change.cut,
          paths = change.paths,
          subjects = subjects,
          conventional = git.conventional(root),
        })
        local label = ('commit message of %d staged files'):format(
          #change.paths
        )
        require('tools.ai').headless(text, root, label, function(answer)
          local lines = M.message(answer)
          if #lines == 0 or lines[1] == '' then return end
          M.comment(
            root,
            bufnr,
            function(prefix) M.insert(bufnr, lines, prefix) end
          )
        end)
      end)
    end)
  end)
end

return M
