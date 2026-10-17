--- The title and description of a pull request, from the branch
---
--- The commits and the diff since the merge base with the branch it goes
--- into are read from git and checked by `tools.ai.check`, then written up
--- by the headless command of `util.ai_policy`. The answer opens in a
--- Markdown buffer to edit before it is pasted into the forge: nothing is
--- sent to GitHub or GitLab from here.
local M = {}

--- The prompt, under `prompts/` of this configuration or of the project's
--- trusted `.nvim` folder
M.PROMPT = 'git/pr.md'

--- Commits read from the branch
M.MAX_COMMITS = 50

local notify = require('util.notify').titled('AI pull request')

--- The prompt for `change`, the branch `branch` going into `base`
---@param prompt DyAiPrompt
---@param ctx { change: DyAiChange, base: string, branch: string, commits: string[], conventional: boolean }
---@return string
function M.build(prompt, ctx)
  local values = {
    base = ctx.base,
    branch = ctx.branch,
    commits = #ctx.commits > 0 and table.concat(ctx.commits, '\n')
      or '(no commits)',
    convention = ctx.conventional
        and 'The title follows Conventional Commits: `type(scope): subject`.'
      or 'The title is a short sentence, in the style of the commits.',
    files = table.concat(ctx.change.paths, '\n'),
    diff = ctx.change.diff
      .. (
        ctx.change.cut
          and ('\n(diff cut at %d KiB)'):format(
            require('tools.ai.git').MAX_DIFF / 1024
          )
        or ''
      ),
    fence = require('tools.ai.prompts').fence(ctx.change.diff),
  }
  return (prompt.body:gsub('{(%a+)}', values))
end

--- Open `answer` in a Markdown buffer to edit, `<localleader>y` copying it
---@param answer string
---@return integer bufnr
function M.show(answer)
  local lines = require('tools.ai.commit').message(answer)
  local bufnr = require('util.scratch').open(lines, {
    name = 'dyai://pull-request',
    filetype = 'markdown',
    split = 'vertical',
    modifiable = true,
  })
  -- Edited before it is pasted: closing its window must not lose the edits
  vim.bo[bufnr].bufhidden = 'hide'
  vim.keymap.set('n', '<localleader>y', function()
    local text =
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    vim.fn.setreg('+', text)
    vim.fn.setreg('"', text)
    notify('Copied the description')
  end, { buffer = bufnr, desc = 'Copy Description' })
  return bufnr
end

--- Describe the branch of the current buffer's work tree for its pull
--- request into `base`, the default branch unless given
---@param base? string
function M.describe(base)
  local prompt = require('tools.ai.prompts').template(M.PROMPT)
  if not prompt then
    return notify('No prompt ' .. M.PROMPT, vim.log.levels.ERROR)
  end
  local git = require('tools.ai.git')
  local function fail(reason, where)
    require('util.ai_audit').record('dyai', 'refused', where, 'pull request')
    notify(reason, vim.log.levels.WARN)
  end
  git.root(vim.api.nvim_get_current_buf(), function(root, err)
    if not root then
      return fail(err --[[@as string]], vim.uv.cwd() or '')
    end
    local function with_base(into)
      git.change(root, into, function(change, why)
        if not change then
          return fail(why --[[@as string]], root)
        end
        git.log(root, {
          '-' .. M.MAX_COMMITS,
          '--format=- %s%n%w(0,2,2)%b',
          into .. '..HEAD',
        }, function(commits)
          require('util.forge').branch(root, function(branch)
            local text = M.build(prompt, {
              change = change,
              base = into,
              branch = branch or 'HEAD',
              commits = commits,
              conventional = git.conventional(root),
            })
            require('tools.ai').headless(
              text,
              root,
              ('pull request into %s'):format(into),
              M.show
            )
          end)
        end)
      end)
    end
    if base and base ~= '' then return with_base(base) end
    git.base(root, function(found, why)
      if not found then
        return fail(why --[[@as string]], root)
      end
      with_base(found)
    end)
  end)
end

return M
