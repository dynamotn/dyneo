local h = require('null-ls.helpers')
local methods = require('null-ls.methods')

--- Milliseconds a `jira` command is given before it is killed
---
--- jira-cli waits on the network for as long as it takes, and with no server
--- to reach -- offline, a VPN down, `jira init` never run -- that is forever.
--- null-ls answers a completion request once every source has, so one hung
--- search left the whole request, harper's words and all, unanswered.
local TIMEOUT = 5000

--- Milliseconds the source stays quiet after a search hung
---
--- A hang is not about the word: the next search would wait out the same
--- timeout, once per word typed, two processes at a time. A query that fails
--- outright -- `project = AB` while no project is called that -- is about
--- the word, and the next one is tried as usual.
local BACKOFF = 5 * 60 * 1000

--- Issue bodies read at once, all from the one Jira
local PARALLEL = 4

--- `vim.uv.now()` before which the source answers nothing, without asking
local quiet_until = 0

--- Run `jira` and hand back the lines it printed, and whether it hung
---
--- `vim.system` rather than `plenary.job`: plenary calls `on_exit` as soon as
--- the process is gone and stops reading, so output still sitting in the pipe
--- was lost and a query dropped its rows every few runs.
---@param args string[]
---@param on_output fun(lines: string[], hung: boolean)
local function jira(args, on_output)
  require('util.system').run(
    vim.list_extend({ 'jira' }, args),
    { timeout = TIMEOUT },
    function(result)
      local hung = result.timed_out or result.missing
      if result.code ~= 0 then return on_output({}, hung) end
      on_output(
        vim.split(result.stdout or '', '\n', { trimempty = true }),
        false
      )
    end
  )
end

--- Split one `--plain` row into the two columns the candidate is built from
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

--- Turn one row into a completion item
---@param kind string `key` completes the issue key, anything else its summary
---@param row string
---@return table? candidate
---@return string? key The issue the candidate stands for
local function candidate_of(kind, row)
  local key, summary = columns(row)
  -- A row missing either column cannot make a label, and an item without one
  -- is not a completion item
  if not key or not summary then return nil, nil end
  return {
    label = kind == 'key' and key or summary,
    detail = row,
    kind = vim.lsp.protocol.CompletionItemKind['Reference'],
    documentation = {
      kind = vim.lsp.protocol.MarkupKind.Markdown,
      -- Replaced by the body of the issue once it has been read
      value = row,
    },
  },
    key
end

--- Milliseconds the typing has to settle before a word is searched
local DEBOUNCE = 300
--- Milliseconds the items found for a word are reused
local CACHE_TTL = 60000
---@type table<string, { time: integer, items: table[] }>
local cache = {}
--- Bumped by each request: a search waiting on a newer one is dropped
local generation = 0

--- Search Jira for `word`, and hand the items to `on_items` on the main loop
---@param word string
---@param on_items fun(items: table[])
local function search(word, on_items)
  local queries = {
    key = 'project = ' .. word,
    text = [[text ~ "*]] .. word .. [[*"]],
  }

  --- Hand the items over, once
  ---
  --- The callback arrives straight off the libuv loop, which is a fast
  --- event context. `done` leads into null-ls and from there into the API,
  --- so it waits for the loop.
  ---@param items table[]
  local function finish(items)
    vim.schedule(function() on_items(items) end)
  end

  --- Read the body of each issue and fill it into the items standing for
  --- it, then hand everything over
  ---
  --- One read per issue, not per row: the two queries overlap, so an
  --- issue found by both would be read twice.
  ---@param items table[]
  ---@param by_key table<string, table[]> Issue key to the items using it
  local function describe(items, by_key)
    local keys = vim.tbl_keys(by_key)
    -- Nothing to read still has to answer, or the request never completes
    if #keys == 0 then return finish(items) end

    -- A few reads at a time, all to one Jira. Every item is settled before
    -- anything is handed over, so nothing is still being written to after.
    table.sort(keys)
    require('util.system').each(keys, PARALLEL, function(key, done)
      jira({ 'issue', 'view', '--plain', key }, function(lines)
        if #lines > 0 then
          local body = table.concat(
            vim.lsp.util.convert_input_to_markdown_lines(lines),
            '\n'
          )
          for _, item in ipairs(by_key[key]) do
            item.documentation.value = body
          end
        end
        done()
      end)
    end, function() finish(items) end)
  end

  local rows = {}
  local pending_searches = vim.tbl_count(queries)

  for kind, query in pairs(queries) do
    local args = {
      'issue',
      'list',
      '--plain',
      '--columns',
      'KEY,SUMMARY,ASSIGNEE',
      '--paginate',
      '10',
      '--no-headers',
      '--jql',
      query,
    }
    jira(args, function(lines, hung)
      -- A query that fails contributes nothing, rather than holding the
      -- whole request back; one that hung keeps the next ones from trying
      if hung then quiet_until = vim.uv.now() + BACKOFF end
      rows[kind] = lines
      pending_searches = pending_searches - 1
      if pending_searches > 0 then return end

      local items, by_key = {}, {}
      for row_kind, list in pairs(rows) do
        for _, row in ipairs(list) do
          local candidate, key = candidate_of(row_kind, row)
          -- The two come and go together, but saying so keeps the key a
          -- `string` rather than a `string?` for whoever reads it next
          if candidate and key then
            table.insert(items, candidate)
            by_key[key] = by_key[key] or {}
            table.insert(by_key[key], candidate)
          end
        end
      end
      describe(items, by_key)
    end)
  end
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
    fn = function(params, done)
      -- Must enable completion for word with >= 2 chars
      local word = params.word_to_complete
      if #word < 2 then
        done({ { items = {}, isIncomplete = false } })
        return
      end
      -- Each search starts up to 22 `jira` processes: a word typed again
      -- (backspace, a second commit) is answered from what was found, and
      -- only the word the typing settles on is searched at all
      local cached = cache[word]
      if cached and vim.uv.now() - cached.time < CACHE_TTL then
        local items = vim.deepcopy(cached.items)
        return done({ { items = items, isIncomplete = #items == 0 } })
      end

      -- Nothing to ask, or a search just hung: answered at once, and as
      -- complete, so the typing that follows does not ask again
      if vim.fn.executable('jira') ~= 1 or vim.uv.now() < quiet_until then
        done({ { items = {}, isIncomplete = false } })
        return
      end
      generation = generation + 1
      local mine = generation
      vim.defer_fn(function()
        if mine ~= generation then
          return done({ { items = {}, isIncomplete = true } })
        end
        search(word, function(items)
          cache[word] = { time = vim.uv.now(), items = vim.deepcopy(items) }
          done({ { items = items, isIncomplete = #items == 0 } })
        end)
      end, DEBOUNCE)
    end,
    async = true,
  },
})
