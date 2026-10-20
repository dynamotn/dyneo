--- `:DyReview`: review a pull request in one place
---
--- The command, and the diff it shows: `tools.review.session` gets the pull
--- request and holds its code until trusted, `tools.review.actions` is what
--- the reviewer does in the diff, `tools.review.pickers` the lists. This
--- module draws drafts on each side of the diff, gives it the keys, keeps
--- the panel beside it, and passes each subcommand on.
local M = {}

local actions = require('tools.review.actions')
local diff = require('tools.review.diff')
local drafts = require('tools.review.drafts')
local panel = require('tools.review.panel')
local pickers = require('tools.review.pickers')
local session = require('tools.review.session')

local notify = require('util.notify').titled('Review')

M.SUBCOMMANDS =
  { 'pick', 'branch', 'ai', 'submit', 'since', 'drafts', 'trust', 'close' }

M.current = session.current
M.open = session.open
M.close = session.close
M.ask_trust = session.ask_trust
M.comment = actions.comment
M.reply = actions.reply
M.toggle_resolve = actions.toggle_resolve
M.ai_action = actions.ai_action
M.jump_ai = actions.jump_ai
M.mark = actions.mark
M.pick = pickers.pick
M.branch = pickers.branch
M.since = pickers.since
M.list_drafts = pickers.drafts

--- Send the open review: `tools.review.submit`, loaded when asked
---@param s? DyReviewSession
function M.submit(s) require('tools.review.submit').run(s) end

--- Run the AI pass over the open review: `tools.review.ai`, loaded when
--- asked
---@param s? DyReviewSession
function M.ai(s) require('tools.review.ai').run(s) end

--- Put the cursor where the session was asked to go, once `side` of `path`
--- is shown
---@param s DyReviewSession
---@param path string
---@param side DyReviewSide
local function jump_to(s, path, side)
  local jump = s.jump
  if not (jump and jump.path == path and jump.side == side) then return end
  s.jump = nil
  local win = diff.window(side)
  if win then
    vim.api.nvim_set_current_win(win)
    pcall(vim.api.nvim_win_set_cursor, win, { jump.line, 0 })
  end
end

--- Draw drafts on a side of the diff, give it the keys, follow it in the
--- panel; what `diff.on_buffer` calls
---@param bufnr integer
---@param path string
---@param side DyReviewSide
function M.on_diff_buffer(bufnr, path, side)
  local s = session.current()
  if not s then return end
  drafts.draw(bufnr, path, side, s.state, s.threads)
  if not s.keyed[bufnr] then
    s.keyed[bufnr] = true
    local map = require('util.plugin').safe_keymap_set
    for _, key in ipairs(actions.keys()) do
      map(key[1], key[2], key[3], { buffer = bufnr, desc = key[4] })
    end
  end
  if side == 'new' then
    panel.open(s)
    panel.follow(s, path)
  end
  jump_to(s, path, side)
end

--- Show `path` (the first file to read, unless given) in the diff
---@param path? string
function M.show(path)
  local s = session.need()
  if not s then return end
  if not path then
    for _, bucket in ipairs(s.buckets) do
      if bucket.kind ~= 'generated' and #bucket.files > 0 then
        path = bucket.files[1].path
        break
      end
    end
    path = path or (s.files[1] and s.files[1].path)
  end
  if not path then
    panel.open(s)
    return notify('The pull request changes no file')
  end
  local shown = diff.open(s, path)
  if shown == 'shown' and s.jump then
    jump_to(s, path, s.jump.side)
  elseif not shown then
    panel.open(s)
  end
end

--- `:DyReview [subcommand]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1] or 'pick'
  if not vim.tbl_contains(M.SUBCOMMANDS, sub) then
    return notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
  end
  local run = {
    pick = M.pick,
    ai = function() M.ai() end,
    branch = M.branch,
    since = M.since,
    drafts = M.list_drafts,
    submit = function() M.submit() end,
    close = function() M.close() end,
    trust = function()
      local s = session.need()
      if not s then return end
      if s.trusted then return notify('The review is trusted already') end
      session.ask_trust(s, true)
    end,
  }
  run[sub]()
end

return M
