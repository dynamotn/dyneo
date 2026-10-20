--- Lists of a review: pull requests to open, drafts, files changed since
---
--- Snacks pickers over pull requests of every forge remote (requested ones
--- first), over the session's drafts, and over the files changed since the
--- last review; choosing one opens it.
local M = {}

local forge = require('tools.review.forge')
local git = require('tools.review.git')
local panel = require('tools.review.panel')
local session = require('tools.review.session')

local notify = require('util.notify').titled('Review')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- How many forge remotes are listed at once by `pick` and `branch`
M.CONCURRENCY = 4

--- A picker over `items`, each `{ text, path, ... }`, opening the chosen one
---@param title string
---@param items table[]
---@param format fun(item: table): table[]
local function pick_items(title, items, format)
  Snacks.picker.pick({
    title = title,
    items = items,
    format = format,
    confirm = function(picker, item)
      picker:close()
      if not item then return end
      local s = session.current()
      if item.line and s then
        s.jump = { path = item.path, side = item.side, line = item.line }
      end
      require('tools.review').show(item.path)
    end,
  })
end

--- Every draft, with its origin and state
function M.drafts()
  local s = session.need()
  if not s then return end
  local origins = { ai = 'AI', user = 'me', forge = 'forge' }
  local items = {}
  for _, d in ipairs(s.state.drafts) do
    local first = vim.split(d.body or '', '\n')[1] or ''
    local cells = {
      origins[d.origin] or d.origin,
      d.state,
      d.severity or '',
      ('%s:%d'):format(d.path, d.line),
      first,
    }
    items[#items + 1] = {
      text = table.concat(cells, ' '),
      cells = cells,
      path = d.path,
      side = d.side,
      line = d.line,
    }
  end
  if #items == 0 then return notify('No drafts yet') end
  local widths = { 5, 7, 10, 0, 0 }
  pick_items('Review drafts', items, function(item)
    local out = {}
    for i, cell in ipairs(item.cells) do
      local hl = i == 1 and 'SnacksPickerLabel'
        or i < 4 and 'SnacksPickerComment'
      out[#out + 1] = { ('%-' .. widths[i] .. 's  '):format(cell), hl }
    end
    return out
  end)
end

--- The files changed since the last review: an interdiff against the
--- `reviewed` ref, or the marked files whose blob moved when it is gone
function M.since()
  local s = session.need()
  if not s then return end
  local function show(paths)
    if #paths == 0 then
      return notify('Nothing changed since your last review')
    end
    local items = vim.tbl_map(
      function(path) return { text = path, path = path } end,
      paths
    )
    pick_items(
      'Changed since your last review',
      items,
      function(item) return { { item.path } } end
    )
  end
  session.rev_parse(s.root, s.refs .. 'reviewed', function(reviewed)
    if not reviewed then
      notify(
        'The ref of your last review is gone: listing files changed since you marked them',
        WARN
      )
      local paths = {}
      for _, file in ipairs(s.files) do
        if panel.mark(s, file) == '⟳' then paths[#paths + 1] = file.path end
      end
      return show(paths)
    end
    git.merge_base(s.root, s.pull.base_sha, reviewed, function(old_base, err)
      if not old_base then
        return notify('No merge base: ' .. tostring(err), ERROR)
      end
      git.interdiff(
        s.root,
        old_base,
        reviewed,
        s.merge_base,
        s.pull.head_sha,
        function(paths, diff_err)
          if not paths then
            return notify('Could not compare: ' .. tostring(diff_err), ERROR)
          end
          show(paths)
        end
      )
    end)
  end)
end

---@alias DyReviewAsk fun(remote: DyForgeRemote, adapter: DyReviewForge, done: fun(found: table[]))

--- Pull requests of the remotes in `list`, a few at a time
---@param list DyForgeRemote[]
---@param fn DyReviewAsk
---@param cb fun(found: table[]) `{ remote, pull }` each
local function query(list, fn, cb)
  local found, skipped = {}, {}
  require('util.system').each(list, M.CONCURRENCY, function(remote, done)
    local adapter, why = forge.for_remote(remote)
    if not adapter then
      skipped[#skipped + 1] = ('%s (%s)'):format(remote.name, why)
      return done()
    end
    fn(remote, adapter, function(more)
      vim.list_extend(found, more)
      done()
    end)
  end, function()
    if #found == 0 and #skipped > 0 then
      notify('Not reviewed here yet: ' .. table.concat(skipped, ', '), WARN)
    end
    cb(found)
  end)
end

--- The forge remotes of the repository, or nil once it said why there are
--- none
---@param cb fun(list: DyForgeRemote[])
local function forge_remotes(cb)
  session.repo_root(function(root, err)
    if not root then return notify('Cannot review here: ' .. err, ERROR) end
    session.remotes(root, function(list)
      if #list == 0 then return notify('No remote on a known forge', WARN) end
      cb(list)
    end)
  end)
end

--- Pull requests of every forge remote
---@param fn DyReviewAsk
---@param cb fun(found: table[]) `{ remote, pull }` each
local function each_forge(fn, cb)
  forge_remotes(function(list) query(list, fn, cb) end)
end

--- Pick an open pull request of any forge remote, requested ones first
function M.pick()
  each_forge(function(remote, adapter, done)
    adapter.list(remote, function(pulls, err, capped)
      if err then notify(('%s: %s'):format(remote.name, err), WARN) end
      if capped then notify(remote.name .. ': only the first pull requests') end
      done(
        vim.tbl_map(
          function(pull) return { remote = remote, pull = pull } end,
          pulls or {}
        )
      )
    end)
  end, function(found)
    if #found == 0 then return notify('No open pull request') end
    table.sort(found, function(a, b)
      if (a.pull.requested or false) ~= (b.pull.requested or false) then
        return a.pull.requested == true
      end
      return (tonumber(a.pull.id) or 0) > (tonumber(b.pull.id) or 0)
    end)
    for _, item in ipairs(found) do
      item.text = ('%s !%s %s %s'):format(
        item.remote.kind,
        item.pull.id,
        item.pull.title,
        item.pull.author
      )
    end
    Snacks.picker.pick({
      title = 'Pull requests',
      items = found,
      format = function(item)
        return {
          {
            ('%-13s'):format(
              session.FORGE_NAMES[item.remote.kind] or item.remote.kind
            ),
            'SnacksPickerComment',
          },
          { ('!%-6s'):format(item.pull.id), 'SnacksPickerLabel' },
          { item.pull.title .. ' ' },
          { item.pull.author, 'SnacksPickerComment' },
          {
            item.pull.requested and '  review requested' or '',
            'DiagnosticWarn',
          },
        }
      end,
      confirm = function(picker, item)
        picker:close()
        if item then session.open(item.remote, item.pull) end
      end,
    })
  end)
end

--- The remote `name` of `list`, else the first in `util.forge.REMOTES`
--- order, else the first
---@param list DyForgeRemote[]
---@param name? string
---@return DyForgeRemote
local function tracked_of(list, name)
  for _, wanted in ipairs({ name, unpack(require('util.forge').REMOTES) }) do
    for _, remote in ipairs(list) do
      if remote.name == wanted then return remote end
    end
  end
  return list[1]
end

--- Review the pull request of the current branch on the remote it tracks.
--- One that only another remote has is never opened unasked: a branch of the
--- same name there may be someone else's.
function M.branch()
  local dir = session.start_dir()
  require('util.forge').branch(dir, function(branch)
    if not branch then
      return notify('Detached HEAD: no branch to review', WARN)
    end
    ---@type DyReviewAsk
    local function ask(remote, adapter, done)
      adapter.for_branch(remote, branch, function(pull, err)
        if err then notify(('%s: %s'):format(remote.name, err), WARN) end
        done(pull and { { remote = remote, pull = pull } } or {})
      end)
    end
    forge_remotes(function(list)
      session.tracked_remote(dir, branch, function(name)
        local tracked = tracked_of(list, name)
        query({ tracked }, ask, function(found)
          if #found > 0 then
            return session.open(found[1].remote, found[1].pull)
          end
          local others = vim.tbl_filter(
            function(remote) return remote ~= tracked end,
            list
          )
          query(others, ask, function(elsewhere)
            if #elsewhere == 0 then
              return notify(
                ('No pull request for %s on %s'):format(branch, tracked.name)
              )
            end
            vim.ui.select(elsewhere, {
              prompt = ('None on %s: review one of another remote?'):format(
                tracked.name
              ),
              format_item = function(item)
                return ('%s !%s %s'):format(
                  item.remote.name,
                  item.pull.id,
                  item.pull.title
                )
              end,
            }, function(item)
              if item then session.open(item.remote, item.pull) end
            end)
          end)
        end)
      end)
    end)
  end)
end

return M
