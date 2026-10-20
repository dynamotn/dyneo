--- Send a review to its forge, once, resuming where it failed
---
--- The pull request is read again first: a head that moved, or a review
--- that cannot be sent, is refused before anything is asked. The reviewer
--- picks a verdict and an optional body, then confirms a summary of exactly
--- what goes out; nothing is written before that. Each draft is marked
--- posted and saved as soon as the forge has it, so a submit cut short sends
--- only the rest when run again, and the verdict goes out only with the
--- last of them. Pending AI drafts never leave. No message names a draft's
--- text.
local M = {}

local drafts = require('tools.review.drafts')
local git = require('tools.review.git')
local session = require('tools.review.session')

local notify = require('util.notify').titled('Review')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- Verdicts a forge refuses without a word of why
M.NEEDS_BODY = { request_changes = true, reject = true }

--- Whether a submit is between its first question and the forge's answer
local busy = false

--- `fn`, run on the main loop: prompts and file writes are not allowed in
--- a fast event
---@param fn function
---@return function
local function main(fn)
  return function(...)
    if not vim.in_fast_event() then return fn(...) end
    local args, n = { ... }, select('#', ...)
    vim.schedule(function() fn(unpack(args, 1, n)) end)
  end
end

--- `n` and `word`, made plural when `n` is not one
---@param n integer
---@param word string
---@param plural? string
---@return string
local function count(n, word, plural)
  return ('%d %s'):format(n, n == 1 and word or (plural or word .. 's'))
end

--- The forge as people name it
---@param s DyReviewSession
---@return string
local function forge_name(s)
  return session.FORGE_NAMES[s.forge] or tostring(s.forge)
end

---@class DyReviewSendPlan
---@field send DyReviewDraft[]
---@field skipped integer Pending AI drafts left out
---@field outside DyReviewDraft[] Line drafts no hunk of the head holds
---@field comments integer
---@field replies integer
---@field resolutions integer
---@field imported integer Drafts pending on the forge already
---@field verdict? { id: string, label: string }
---@field body? string

--- Count what `plan.send` holds
---@param plan DyReviewSendPlan
local function tally(plan)
  for _, draft in ipairs(plan.send) do
    if draft.origin == 'forge' then
      plan.imported = plan.imported + 1
    elseif draft.reply_to then
      if draft.resolve then plan.resolutions = plan.resolutions + 1 end
      if draft.body ~= '' then plan.replies = plan.replies + 1 end
    else
      plan.comments = plan.comments + 1
    end
  end
end

--- Find the line drafts of `plan` that lie outside the diff of the head,
--- reading the hunks of files not read yet
---@param s DyReviewSession
---@param plan DyReviewSendPlan
---@param cb fun(err?: string)
local function revalidate(s, plan, cb)
  local lines, missing, seen = {}, {}, {}
  for _, draft in ipairs(plan.send) do
    if
      draft.origin ~= 'forge'
      and not draft.reply_to
      and not draft.file_level
    then
      lines[#lines + 1] = draft
      if not s.hunks[draft.path] and not seen[draft.path] then
        seen[draft.path] = true
        missing[#missing + 1] = session.file_of(s, draft.path)
          or { path = draft.path }
      end
    end
  end
  local function check()
    for _, draft in ipairs(lines) do
      local hunks = s.hunks[draft.path]
      if not hunks then
        return cb(('Could not read the diff of %s'):format(draft.path))
      end
      if
        not drafts.in_hunk(hunks, draft.side, draft.line, draft.start_line)
      then
        plan.outside[#plan.outside + 1] = draft
      end
    end
    cb()
  end
  if #missing == 0 then return check() end
  session.load_hunks(
    s,
    missing,
    main(function(err)
      if err then
        return cb(
          ('Could not read the diff of %s: %s'):format(missing[1].path, err)
        )
      end
      check()
    end)
  )
end

--- What the confirmation shows: counts, paths and lines, and the body
---@param s DyReviewSession
---@param plan DyReviewSendPlan
---@return string
function M.summary(s, plan)
  local lines = {
    ('Send this review to %s?'):format(forge_name(s)),
    '',
    ('Pull request: %s !%s %s'):format(s.remote.slug, s.pull.id, s.pull.title),
    'Verdict: ' .. plan.verdict.label,
    ('%s, %s, %s'):format(
      count(plan.comments, 'comment'),
      count(plan.replies, 'reply', 'replies'),
      count(plan.resolutions, 'resolution')
    ),
  }
  if plan.imported > 0 then
    lines[#lines + 1] = ('%s already pending on %s %s published as %s'):format(
      count(plan.imported, 'draft'),
      forge_name(s),
      plan.imported == 1 and 'is' or 'are',
      plan.imported == 1 and 'it is' or 'they are'
    )
  end
  if plan.skipped > 0 then
    lines[#lines + 1] = ('%s %s skipped'):format(
      count(plan.skipped, 'pending AI draft'),
      plan.skipped == 1 and 'is' or 'are'
    )
  end
  if #plan.outside > 0 then
    lines[#lines + 1] = ('%s outside the current diff: %s sent as file comments naming the line'):format(
      #plan.outside == 1 and '1 draft points'
        or (#plan.outside .. ' drafts point'),
      #plan.outside == 1 and 'it is' or 'they are'
    )
    for _, draft in ipairs(plan.outside) do
      lines[#lines + 1] = ('  %s:%d'):format(draft.path, draft.line)
    end
  end
  if plan.body then
    vim.list_extend(lines, { '', 'Body:' })
    vim.list_extend(lines, vim.split(plan.body, '\n', { plain = true }))
  end
  return table.concat(lines, '\n')
end

--- Ask for the body; a verdict that needs one with nothing else said asks
--- until one is given or the reviewer gives up
---@param plan DyReviewSendPlan
---@param cb fun(ok: boolean)
local function ask_body(plan, cb)
  local needed = M.NEEDS_BODY[plan.verdict.id]
    and plan.comments + plan.replies + plan.imported == 0
  vim.ui.input(
    {
      prompt = needed and 'Body of the review (needed): '
        or 'Body of the review (optional): ',
    },
    main(function(text)
      if text == nil then return cb(false) end
      text = vim.trim(text)
      if text ~= '' then
        plan.body = text
        return cb(true)
      end
      if needed then
        notify(
          ('%s with no comment needs a body'):format(plan.verdict.label),
          WARN
        )
        return ask_body(plan, cb)
      end
      cb(true)
    end)
  )
end

--- Clear `posted` on the drafts the forge lost, if the reviewer says so,
--- and submit again
---@param s DyReviewSession
---@param lost string[]
local function offer_resend(s, lost)
  local question = ('%s went into a pending review deleted on %s. Send %s again?'):format(
    count(#lost, 'draft'),
    forge_name(s),
    #lost == 1 and 'it' or 'them'
  )
  if vim.fn.confirm(question, '&Yes\n&No', 2) ~= 1 then
    return notify('Not sent again: they stay marked as sent', WARN)
  end
  local ids = {}
  for _, id in ipairs(lost) do
    ids[id] = true
  end
  for _, draft in ipairs(s.state.drafts) do
    if ids[draft.id] then draft.posted = nil end
  end
  session.save(s)
  M.run(s)
end

--- Record a whole submit: the head reviewed, and the `reviewed` ref
---@param s DyReviewSession
---@param plan DyReviewSendPlan
---@param info? { already?: integer, skipped?: string }
local function done(s, plan, info)
  local head = s.pull.head_sha
  s.state.last_head = head
  session.changed(s)
  git.update_ref(
    s.root,
    s.refs .. 'reviewed',
    head,
    main(function(ok, err)
      if not ok then
        notify('Could not mark the head reviewed: ' .. (err or '?'), WARN)
      end
    end)
  )
  if info and info.already then
    notify(
      ('This review was already out on %s (review %s): only the resolutions were sent'):format(
        forge_name(s),
        tostring(info.already)
      )
    )
  elseif info and info.skipped then
    notify(
      ('Only the resolutions were sent: %s takes no empty comment review'):format(
        forge_name(s)
      )
    )
  else
    notify(
      ('Review sent to %s: !%s, %s'):format(
        forge_name(s),
        s.pull.id,
        plan.verdict.label
      )
    )
  end
end

--- Hand the confirmed plan to the forge, saving each draft as it lands
---@param s DyReviewSession
---@param plan DyReviewSendPlan
---@param finish fun()
local function send(s, plan, finish)
  for _, draft in ipairs(plan.outside) do
    draft.file_level = true
  end
  if #plan.outside > 0 then session.save(s) end
  local called, raised = pcall(
    s.adapter.submit,
    s.remote,
    s.pull,
    plan.send,
    { verdict = plan.verdict.id, body = plan.body },
    function(draft, forge_id)
      -- Marked at once, so an answer arriving before the save sees it
      draft.posted = forge_id
      main(session.save)(s)
    end,
    main(function(err, info)
      finish()
      if err then
        session.changed(s)
        notify(
          ('Review not sent: %s. Drafts the forge has are kept as sent; `:DyReview submit` sends the rest'):format(
            err
          ),
          ERROR
        )
        if info and info.lost and #info.lost > 0 then
          offer_resend(s, info.lost)
        end
        return
      end
      done(s, plan, info)
    end)
  )
  if not called then
    finish()
    session.changed(s)
    notify('Review not sent: ' .. tostring(raised), ERROR)
  end
end

--- Ask for the verdict and body, confirm, then send
---@param s DyReviewSession
---@param plan DyReviewSendPlan
---@param finish fun()
local function ask(s, plan, finish)
  local verdicts = s.adapter.verdicts or {}
  if #verdicts == 0 then
    finish()
    return notify(forge_name(s) .. ' takes no verdict from here', WARN)
  end
  vim.ui.select(
    verdicts,
    {
      prompt = 'Verdict of the review',
      format_item = function(item) return item.label end,
    },
    main(function(choice)
      if not choice then
        finish()
        return notify('Not sent')
      end
      plan.verdict = choice
      ask_body(plan, function(ok)
        if not ok then
          finish()
          return notify('Not sent')
        end
        local said = plan.comments + plan.replies + plan.imported
        if said + plan.resolutions == 0 and not plan.body then
          finish()
          return notify('Nothing to send: no draft and no body', WARN)
        end
        if vim.fn.confirm(M.summary(s, plan), '&Send\n&Cancel', 2) ~= 1 then
          finish()
          return notify('Not sent')
        end
        if session.current() ~= s then
          finish()
          return notify('The review was closed: nothing sent', WARN)
        end
        send(s, plan, finish)
      end)
    end)
  )
end

--- `:DyReview submit`: send the review of session `s` (the open one)
---@param s? DyReviewSession
function M.run(s)
  s = s or session.need()
  if not s then return end
  if busy then return notify('A submit is already running', WARN) end
  local blocked = s.blocked or s.pull.read_only
  if blocked then return notify('Not sent: ' .. blocked, WARN) end
  busy = true
  local function finish() busy = false end
  local called, raised = pcall(
    s.adapter.get,
    s.remote,
    s.pull.id,
    main(function(pull, err)
      if not pull then
        finish()
        return notify(
          'Could not read the pull request again: ' .. (err or 'no answer'),
          ERROR
        )
      end
      if session.current() ~= s then
        finish()
        return notify('The review was closed: nothing sent', WARN)
      end
      if pull.head_sha ~= s.pull.head_sha then
        finish()
        return notify(
          ('The pull request moved to %s: reopen it before submitting'):format(
            pull.head_sha:sub(1, 7)
          ),
          WARN
        )
      end
      if pull.read_only then
        finish()
        return notify('Not sent: ' .. pull.read_only, WARN)
      end
      local list, skipped = drafts.sendable(s.state)
      ---@type DyReviewSendPlan
      local plan = {
        send = list,
        skipped = skipped,
        outside = {},
        comments = 0,
        replies = 0,
        resolutions = 0,
        imported = 0,
      }
      tally(plan)
      revalidate(s, plan, function(why)
        if why then
          finish()
          return notify('Not sent: ' .. why, ERROR)
        end
        ask(s, plan, finish)
      end)
    end)
  )
  if not called then
    finish()
    notify('Could not read the pull request again: ' .. tostring(raised), ERROR)
  end
end

return M
