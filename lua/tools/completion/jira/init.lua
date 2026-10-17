local h = require('null-ls.helpers')
local methods = require('null-ls.methods')

--- Milliseconds a `jira` command is given before it is killed
---
--- jira-cli waits on the network for as long as it takes, and with no server
--- to reach -- offline, a VPN down, `jira init` never run -- that is forever.
local TIMEOUT = 5000

--- Milliseconds the source stays quiet after the list hung
---
--- A hang is not about the moment: the next read would wait out the same
--- timeout. A query that fails outright is read again at the next refresh.
local BACKOFF = 5 * 60 * 1000

--- Milliseconds the issues read are kept before a request reads them again
local REFRESH = 5 * 60 * 1000

--- The issues kept: the most recently updated the user can see. jira-cli
--- reads at most a hundred a page, and one page is all that is read.
local MAX_ISSUES = 100

--- Which issues are kept
local JQL = 'updated >= -30d ORDER BY updated DESC'

--- Items answered for one word, the best matches first
local MAX_ITEMS = 50

---@class DyJiraIssue
---@field key string
---@field summary string
---@field row string The `--plain` row it was read from

--- The issues read last, and the state of their reading
local state = {
  ---@type DyJiraIssue[]
  issues = {},
  --- `vim.uv.now()` of the last read that answered, 0 before any
  read_at = 0,
  --- `vim.uv.now()` before which nothing is read
  quiet_until = 0,
  reading = false,
}

--- Split one `--plain` row into the two columns an item is built from
---@param row string A `KEY\tSUMMARY\tASSIGNEE` line
---@return string? key
---@return string? summary
local function columns(row)
  local key, summary
  for column in string.gmatch(row, '[^\t]+') do
    if not key then
      key = column
    elseif not summary then
      summary = column
    end
  end
  return key, summary
end

--- Read the issues again in the background, unless a read is under way, the
--- list is fresh, or the last read hung a moment ago
local function refresh()
  local now = vim.uv.now()
  if
    state.reading
    or now < state.quiet_until
    or (state.read_at > 0 and now - state.read_at < REFRESH)
  then
    return
  end
  state.reading = true
  require('util.system').run({
    'jira',
    'issue',
    'list',
    '--plain',
    '--columns',
    'KEY,SUMMARY,ASSIGNEE',
    '--paginate',
    tostring(MAX_ISSUES),
    '--no-headers',
    '--jql',
    JQL,
  }, { timeout = TIMEOUT, max_bytes = 1024 * 1024 }, function(result)
    state.reading = false
    if result.timed_out or result.missing then
      state.quiet_until = vim.uv.now() + BACKOFF
      return
    end
    -- A failed read keeps the issues there were, and is tried again on the
    -- next request
    if result.code ~= 0 then return end
    local issues = {}
    for _, row in ipairs(vim.split(result.stdout or '', '\n')) do
      local key, summary = columns(row)
      -- A row missing either column cannot make a label
      if key and summary and #issues < MAX_ISSUES then
        table.insert(issues, { key = key, summary = summary, row = row })
      end
    end
    state.issues = issues
    state.read_at = vim.uv.now()
  end)
end

--- A completion item for `issue`, labelled by its key or its summary
---@param issue DyJiraIssue
---@param label string
---@return table
local function item(issue, label)
  return {
    label = label,
    detail = issue.row,
    kind = vim.lsp.protocol.CompletionItemKind['Reference'],
    documentation = {
      kind = vim.lsp.protocol.MarkupKind.Markdown,
      value = issue.row,
    },
  }
end

--- The items of the issues kept that `word` matches: a key it starts, a
--- summary it is found in
---@param word string
---@return table[]
local function items_for(word)
  local lower = word:lower()
  local items = {}
  for _, issue in ipairs(state.issues) do
    if #items >= MAX_ITEMS then break end
    if vim.startswith(issue.key:lower(), lower) then
      table.insert(items, item(issue, issue.key))
    end
    if issue.summary:lower():find(lower, 1, true) then
      table.insert(items, item(issue, issue.summary))
    end
  end
  return vim.list_slice(items, 1, MAX_ITEMS)
end

return h.make_builtin({
  name = 'jira',
  meta = {
    description = 'My custom source to complete JIRA issues',
    url = 'https://github.com/ankitpokhrel/jira-cli',
  },
  method = methods.internal.COMPLETION,
  filetypes = { 'gitcommit' },
  generator = {
    -- Answered from the issues kept, never by a `jira` per word typed: the
    -- list is read again in the background once it is stale
    fn = function(params, done)
      local word = params.word_to_complete
      if #word < 2 or vim.fn.executable('jira') ~= 1 then
        return done({ { items = {}, isIncomplete = false } })
      end
      refresh()
      -- Asked again while the first read is still out
      local waiting = state.reading and state.read_at == 0
      done({ { items = items_for(word), isIncomplete = waiting } })
    end,
    async = true,
  },
})
