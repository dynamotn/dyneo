--- Send a review to its forge, once, resuming where it failed
---
--- The pull request is read again first: a head that moved, or a review
--- that cannot be sent, is refused before anything is asked. The reviewer
--- picks a verdict and an optional body, then confirms a summary of exactly
--- what goes out; nothing is written before that. Each draft is marked
--- posted and saved as soon as the forge has it, so a submit cut short sends
--- only the rest when run again, and the verdict goes out only with the
--- last of them. The adapter is handed every draft of this round it must
--- check, posted ones included: it skips those itself, and needs them to
--- tell a review already out or drafts lost with a deleted pending review.
--- A whole submit retires every posted draft (`done`), so a later round
--- never hands them over again: what happened to them on the forge since is
--- no business of that round. Dropped and pending AI drafts never leave. No
--- message names a draft's text.
local M = {}

local drafts = require('tools.review.drafts')
local git = require('tools.review.git')
local session = require('tools.review.session')

local notify = require('util.notify').titled('Review')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- Verdicts a forge refuses without a word of why
M.NEEDS_BODY = { request_changes = true }

--- Whether a submit is between its first question and the forge's answer
local busy = false

--- Whether a review is being sent: closing or opening one waits for it
---@return boolean
function M.busy() return busy end

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
---@field send DyReviewDraft[] What the adapter is handed, posted ones of
--- this round too
---@field unposted DyReviewDraft[] What goes out now
---@field skipped integer Pending AI drafts left out
---@field outside DyReviewDraft[] Line drafts no hunk of the head holds
---@field comments integer
---@field replies integer
---@field resolutions integer
---@field imported integer Drafts pending on the forge already
---@field verdict? { id: string, label: string }
---@field body? string

--- Count what `plan.unposted` holds
---@param plan DyReviewSendPlan
local function tally(plan)
  for _, draft in ipairs(plan.unposted) do
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
  for _, draft in ipairs(plan.unposted) do
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

--- The plan of what the state holds now: every draft but dropped and
--- pending AI ones for the adapter, the unposted ones counted
---@param s DyReviewSession
---@param cb fun(plan?: DyReviewSendPlan, err?: string)
local function build(s, cb)
  ---@type DyReviewSendPlan
  local plan = {
    send = {},
    unposted = {},
    skipped = 0,
    outside = {},
    comments = 0,
    replies = 0,
    resolutions = 0,
    imported = 0,
  }
  for _, draft in ipairs(s.state.drafts) do
    if draft.state == 'dropped' or draft.done then
      -- not wanted, or out with an earlier review
    elseif draft.origin == 'ai' and draft.state == 'pending' then
      plan.skipped = plan.skipped + 1
    else
      plan.send[#plan.send + 1] = draft
      if not draft.posted then plan.unposted[#plan.unposted + 1] = draft end
    end
  end
  tally(plan)
  revalidate(s, plan, function(err)
    if err then return cb(nil, err) end
    cb(plan)
  end)
end

--- What of `plan` the confirmation answers for: the drafts going out, their
--- words and places, and what is left out
---@param plan DyReviewSendPlan
---@return string
local function signature(plan)
  local parts = { tostring(plan.skipped), tostring(#plan.send) }
  local outside = {}
  for _, draft in ipairs(plan.outside) do
    outside[draft] = true
  end
  for _, draft in ipairs(plan.unposted) do
    parts[#parts + 1] = vim.inspect({
      draft.id,
      draft.body,
      draft.suggestion,
      draft.resolve,
      draft.path,
      draft.line,
      draft.start_line,
      draft.file_level or outside[draft] or false,
    })
  end
  return table.concat(parts, '\n')
end

--- Whether `plan`'s verdict needs a body it lacks
---@param plan DyReviewSendPlan
---@return boolean
local function lacks_body(plan)
  return M.NEEDS_BODY[plan.verdict.id] == true
    and plan.comments + plan.replies + plan.imported == 0
    and not plan.body
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
  local needed = lacks_body(plan)
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
---@param info? { already?: integer, skipped?: string, mark?: integer }
local function done(s, plan, info)
  local head = s.pull.head_sha
  s.state.last_head = head
  for _, draft in ipairs(s.state.drafts) do
    if draft.posted and not draft.done then draft.done = head end
  end
  local mark = info and info.mark
  if type(mark) == 'number' and mark > (s.state.mark or -1) then
    s.state.mark = mark
  end
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
    { verdict = plan.verdict.id, body = plan.body, since = s.state.mark },
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

--- Read the pull request again and check it can still take this review
---@param s DyReviewSession
---@param cb fun(err?: string, level?: integer) An error refuses the submit
local function check_pull(s, cb)
  local called, raised = pcall(
    s.adapter.get,
    s.remote,
    s.pull.id,
    main(function(pull, err)
      if not pull then
        return cb(
          'Could not read the pull request again: ' .. (err or 'no answer'),
          ERROR
        )
      end
      if session.current() ~= s then
        return cb('The review was closed: nothing sent', WARN)
      end
      if pull.head_sha ~= s.pull.head_sha then
        return cb(
          ('The pull request moved to %s: reopen it before submitting'):format(
            pull.head_sha:sub(1, 7)
          ),
          WARN
        )
      end
      if pull.read_only then return cb('Not sent: ' .. pull.read_only, WARN) end
      cb()
    end)
  )
  if not called then
    cb('Could not read the pull request again: ' .. tostring(raised), ERROR)
  end
end

--- Show the confirmation of `plan`; on yes, check the pull request and the
--- drafts once more, and send only if both are still what was shown
---@param s DyReviewSession
---@param plan DyReviewSendPlan
---@param finish fun()
local function confirm(s, plan, finish)
  if lacks_body(plan) then
    return ask_body(plan, function(ok)
      if not ok then
        finish()
        return notify('Not sent')
      end
      confirm(s, plan, finish)
    end)
  end
  local shown = signature(plan)
  if vim.fn.confirm(M.summary(s, plan), '&Send\n&Cancel', 2) ~= 1 then
    finish()
    return notify('Not sent')
  end
  check_pull(s, function(err, level)
    if err then
      finish()
      return notify(err, level)
    end
    build(s, function(now, why)
      if not now then
        finish()
        return notify('Not sent: ' .. (why or '?'), ERROR)
      end
      now.verdict, now.body = plan.verdict, plan.body
      if signature(now) ~= shown then
        notify('The drafts changed while asking: confirm again', WARN)
        return confirm(s, now, finish)
      end
      send(s, now, finish)
    end)
  end)
end

--- Ask for the verdict and body, then confirm
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
        confirm(s, plan, finish)
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
  check_pull(s, function(err, level)
    if err then
      finish()
      return notify(err, level)
    end
    build(s, function(plan, why)
      if not plan then
        finish()
        return notify('Not sent: ' .. (why or '?'), ERROR)
      end
      ask(s, plan, finish)
    end)
  end)
end

return M
