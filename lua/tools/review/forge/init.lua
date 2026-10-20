--- The one interface every forge of `:DyReview` answers to
---
--- The session and the submit only ever call a `DyReviewForge`; each forge's
--- adapter maps its own API onto it.
local M = {}

---@class DyReviewPull
---@field id string                 number or iid, as text
---@field title string
---@field author string
---@field body string
---@field url string
---@field base_ref string
---@field head_ref string
---@field base_sha string
---@field head_sha string
---@field fetch string[]            refspecs giving head (and base)
---@field fork boolean
---@field requested? boolean        my review is requested
---@field read_only? string         why nothing can be sent, when it cannot

---@class DyReviewComment
---@field author string
---@field body string
---@field time string

---@class DyReviewThread
---@field id string
---@field path? string
---@field side 'old'|'new'
---@field line? integer
---@field start_line? integer
---@field resolved boolean
---@field comments DyReviewComment[]

---@class DyReviewForge
---@field verdicts { id: string, label: string }[]
---@field list fun(remote: DyForgeRemote, cb: fun(pulls?: DyReviewPull[], err?: string, capped?: boolean))
---@field for_branch fun(remote: DyForgeRemote, branch: string, cb: fun(pull?: DyReviewPull, err?: string))
---@field get fun(remote: DyForgeRemote, id: string, cb: fun(pull?: DyReviewPull, err?: string))
---@field threads fun(remote: DyForgeRemote, pull: DyReviewPull, cb: fun(threads?: DyReviewThread[], err?: string, capped?: boolean))
---@field pending fun(remote: DyForgeRemote, pull: DyReviewPull, cb: fun(drafts?: DyReviewDraft[], err?: string))
---@field submit fun(remote: DyForgeRemote, pull: DyReviewPull, drafts: DyReviewDraft[], review: { verdict: string, body?: string }, progress: fun(draft: DyReviewDraft, forge_id: string), cb: fun(err?: string, info?: { lost?: string[], already?: integer, skipped?: string }))
---@field suggestion fun(lines: string[]): string?

--- The module of each forge kind's adapter
M.ADAPTERS = { github = 'tools.review.forge.github' }

--- The adapter answering for `remote`'s forge
---@param remote DyForgeRemote
---@return DyReviewForge? adapter
---@return string? err
function M.for_remote(remote)
  local name = M.ADAPTERS[remote.kind]
  if not name then return nil, 'not yet supported' end
  return require(name)
end

return M
