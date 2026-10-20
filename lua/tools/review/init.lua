--- `:DyReview`: review a pull request in one place
---
--- A session fetches the pull request into private refs, reads its change
--- from local git, checks the head out into a detached worktree under the
--- repository's `.worktrees/`, and shows a triage panel beside codediff's
--- diff of each file. The worktree is held untrusted before any of its
--- buffers opens: no language server and no `.nvim` folder runs the author's
--- code until the reviewer says yes, once per pull request and head. Drafts
--- live in `tools.review.store`, threads and pending drafts come from the
--- forge's adapter. The user's checkout, index, branch and cwd are never
--- touched.
local M = {}

local diff = require('tools.review.diff')
local drafts = require('tools.review.drafts')
local forge = require('tools.review.forge')
local git = require('tools.review.git')
local panel = require('tools.review.panel')
local store = require('tools.review.store')
local triage = require('tools.review.triage')
local untrusted = require('util.untrusted')

local notify = require('util.notify').titled('Review')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

M.SUBCOMMANDS =
  { 'pick', 'branch', 'ai', 'submit', 'since', 'drafts', 'trust', 'close' }

--- Where a pull request's refs live: `<prefix><forge>-<id>/{head,base,reviewed}`
M.REF_PREFIX = 'refs/dyneo/review/'

--- How many forge remotes are listed at once by `pick` and `branch`
M.CONCURRENCY = 4

--- The forge as the trust question names it
M.FORGE_NAMES = { github = 'GitHub', gitlab = 'GitLab', azure = 'Azure DevOps' }

---@class DyReviewSession
---@field remote DyForgeRemote
---@field forge DyForgeKind
---@field adapter DyReviewForge
---@field pull DyReviewPull
---@field root string The main checkout of the repository
---@field worktree string The head, checked out detached
---@field refs string Prefix of the pull request's private refs
---@field merge_base string
---@field files DyReviewFile[] Each with `blob`, its id at the head
---@field buckets DyReviewBucket[]
---@field hunks table<string, DyReviewHunks> By path, read as needed
---@field threads DyReviewThread[]
---@field state DyReviewState
---@field trusted boolean
---@field blocked? string Why nothing can be sent
---@field collapsed? table<DyReviewKind, boolean>
---@field panel_buf? integer
---@field panel_rows? table<integer, DyReviewPanelRow>
---@field keyed table<integer, boolean> Buffers given the review's keys
---@field jump? { path: string, side: DyReviewSide, line: integer }
---@field told_deps? boolean

---@class DyReviewFile
---@field blob? string Its id at the head, nil when the head deletes it

---@type DyReviewSession?
local session
local opening = false

--- Trust verdicts by pull request and head, kept past a session's close
---@type table<string, boolean>
local verdicts = {}

---@return DyReviewSession?
function M.current() return session end

--- The session, or nil with a message saying how to start one
---@return DyReviewSession?
local function need()
  if not session then
    notify('No review is open: `:DyReview` picks one', WARN)
  end
  return session
end

--- Write the session's state; a failure is said and the state kept in memory
---@param s DyReviewSession
local function save(s)
  local ok, err = pcall(store.save, s.remote, s.pull.id, s.state)
  if not ok then
    notify('Could not save the review: ' .. tostring(err), ERROR)
  end
end

--- Save, then draw the drafts and the panel again
---@param s DyReviewSession
local function changed(s)
  save(s)
  diff.redraw()
  panel.refresh(s)
end

--- The directory the review starts from: the current file's, else the cwd
---@return string
local function start_dir()
  local dir = vim.fn.expand('%:p:h')
  return vim.fn.isdirectory(dir) == 1 and dir or vim.uv.cwd() or '.'
end

--- Run git in `dir`, its first output line or nil
---@param dir string
---@param args string[]
---@param cb fun(out?: string)
local function git_line(dir, args, cb)
  require('util.system').run(
    vim.list_extend({ 'git' }, args),
    { cwd = dir, timeout = git.TIMEOUT },
    function(result)
      local out = vim.trim(result.stdout or ''):match('^[^\n]*')
      cb((result.code == 0 and out ~= '') and out or nil)
    end
  )
end

--- The main checkout of the repository around `start_dir()`
---@param cb fun(root?: string, err?: string)
function M.repo_root(cb)
  local args = { 'rev-parse', '--path-format=absolute', '--git-common-dir' }
  git_line(start_dir(), args, function(dir)
    if not dir then return cb(nil, 'not in a git repository') end
    if vim.fs.basename(dir) ~= '.git' then
      return cb(nil, 'a bare repository has no checkout for a worktree')
    end
    cb(vim.fs.dirname(dir))
  end)
end

--- The commit `rev` names in `dir`, nil when it is gone
---@param dir string
---@param rev string
---@param cb fun(sha?: string)
local function rev_parse(dir, rev, cb)
  local args = { 'rev-parse', '--verify', '--quiet', '--end-of-options' }
  git_line(dir, vim.list_extend(args, { rev .. '^{commit}' }), cb)
end

--- Every remote of `root` on a known forge, one per repository
---@param root string
---@param cb fun(remotes: DyForgeRemote[])
local function remotes(root, cb)
  local util_forge = require('util.forge')
  require('util.system').run(
    { 'git', 'config', '--get-regexp', [[^remote\..*\.url$]] },
    { cwd = root, timeout = git.TIMEOUT },
    function(result)
      local found, seen = {}, {}
      for name, url in
        (result.stdout or ''):gmatch('remote%.(%S+)%.url%s+(%S+)')
      do
        local remote = util_forge.pick_remote({ [name] = url })
        -- `pick_remote` only knows the usual names; any other is a remote too
        if not remote then
          local host, slug = util_forge.parse_url(url)
          local kind = host and util_forge.kind_of(host)
          if kind and kind ~= 'azure' then
            remote = {
              name = name,
              host = host --[[@as string]],
              slug = slug --[[@as string]],
              kind = kind,
            }
          end
        end
        local key = remote and (remote.host .. '/' .. remote.slug)
        if key and not seen[key] then
          seen[key] = true
          found[#found + 1] = remote
        end
      end
      table.sort(found, function(a, b) return a.name < b.name end)
      cb(found)
    end
  )
end

--- The question asked before the author's code may run
---@param s DyReviewSession
---@return string
local function trust_question(s)
  return ("Review %s !%s by %s%s: let language servers and the project's .nvim run its code?"):format(
    M.FORGE_NAMES[s.forge] or s.forge,
    s.pull.id,
    s.pull.author,
    s.pull.fork and ' (from a fork)' or ''
  )
end

--- Ask whether the worktree's code may run, once per pull request and head
---
--- The verdict is pinned to "no" before the prompt, which keeps handling
--- events and would otherwise ask again. `util.trust` is not used: it
--- answers no for a held directory without asking.
---@param s DyReviewSession
---@param again? boolean Ask even when a verdict is known
function M.ask_trust(s, again)
  if s ~= session or s.trusted then return end
  local key = ('review:%s:%s:%s:%s'):format(
    s.forge,
    s.remote.slug,
    s.pull.id,
    s.pull.head_sha
  )
  local yes = verdicts[key]
  if yes == nil or again then
    verdicts[key] = false
    yes = vim.fn.confirm(trust_question(s), '&Yes\n&No', 2) == 1
    verdicts[key] = yes
    if not yes then notify('Diff only: `:DyReview trust` asks again') end
  end
  if yes and s == session then
    s.trusted = true
    untrusted.release(s.worktree)
    panel.refresh(s)
  end
end

--- Read the hunks of `files` that have none yet, a few at a time
---@param s DyReviewSession
---@param files DyReviewFile[]
---@param cb fun(err?: string)
local function load_hunks(s, files, cb)
  local failed
  require('util.system').each(files, git.CONCURRENCY, function(file, done)
    git.hunks(
      s.root,
      s.merge_base,
      s.pull.head_sha,
      file.path,
      file.old_path,
      function(hunks, err)
        s.hunks[file.path] = hunks
        failed = failed or err
        done()
      end
    )
  end, function() cb(failed) end)
end

--- The file `path` of the session
---@param s DyReviewSession
---@param path string
---@return DyReviewFile?
local function file_of(s, path)
  for _, file in ipairs(s.files) do
    if file.path == path then return file end
  end
end

--- Make the worktree, or take the one an earlier session left at the head
---@param s DyReviewSession
---@param cb fun(ok: boolean, err?: string)
local function worktree(s, cb)
  if not vim.uv.fs_stat(s.worktree) then
    return git.worktree_add(s.root, s.worktree, s.pull.head_sha, cb)
  end
  rev_parse(s.worktree, 'HEAD', function(sha)
    if sha == s.pull.head_sha then return cb(true) end
    cb(
      false,
      ('%s holds another version of the pull request: remove it with `git worktree remove`'):format(
        s.worktree
      )
    )
  end)
end

--- Read threads and import my pending drafts from the forge, then `cb`
---@param s DyReviewSession
---@param cb fun()
local function load_forge(s, cb)
  local left = 2
  local function done()
    left = left - 1
    if left == 0 then cb() end
  end
  s.adapter.threads(s.remote, s.pull, function(threads, err, capped)
    s.threads = threads or {}
    if err then notify('Could not read the threads: ' .. err, WARN) end
    if capped then notify('Only the first threads were read', WARN) end
    done()
  end)
  s.adapter.pending(s.remote, s.pull, function(pending, err)
    if not pending then
      s.blocked = s.blocked
        or ('Your pending review could not be read: %s'):format(
          err or 'no answer'
        )
    else
      local kept = vim.tbl_filter(
        function(d) return d.origin ~= 'forge' or d.posted ~= nil end,
        s.state.drafts
      )
      s.state.drafts = vim.list_extend(kept, pending)
    end
    done()
  end)
end

--- Say once that servers run without the project's dependencies
---@param s DyReviewSession
local function autocmds(s)
  local group = vim.api.nvim_create_augroup('dy_review', { clear = true })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      if s ~= session or s.told_deps then return end
      local name = vim.api.nvim_buf_get_name(args.buf)
      local real = vim.uv.fs_realpath(name) or name
      local dir = vim.uv.fs_realpath(s.worktree) or s.worktree
      if vim.startswith(real, dir .. '/') then
        s.told_deps = true
        notify(
          'Dependencies are not installed in the review worktree: some servers answer only in part'
        )
      end
    end,
  })
end

--- Open a review of `pull` on `remote`, or show the one already open
---@param remote DyForgeRemote
---@param pull DyReviewPull
function M.open(remote, pull)
  if
    session
    and session.remote.host == remote.host
    and session.remote.slug == remote.slug
    and session.pull.id == pull.id
  then
    return M.show()
  end
  if opening then return notify('A review is already opening', WARN) end
  local adapter, why = forge.for_remote(remote)
  if not adapter then
    return notify(('%s: %s'):format(remote.kind, why or 'no adapter'), WARN)
  end
  if session then M.close() end
  opening = true
  local function fail(what, reason)
    opening = false
    notify(('%s: %s'):format(what, reason or 'unknown error'), ERROR)
  end
  M.repo_root(function(root, root_err)
    if not root then return fail('Cannot review here', root_err) end
    local head = pull.head_sha
    local refs = ('%s%s-%s/'):format(M.REF_PREFIX, remote.kind, pull.id)
    local dir = ('dyreview-%s-%s'):format(remote.kind, pull.id)
    ---@type DyReviewSession
    local s = {
      remote = remote,
      forge = remote.kind,
      adapter = adapter,
      pull = pull,
      root = root,
      worktree = vim.fs.joinpath(root, '.worktrees', dir),
      refs = refs,
      merge_base = '',
      files = {},
      buckets = {},
      hunks = {},
      threads = {},
      state = { reviewed = {}, drafts = {} },
      trusted = false,
      blocked = pull.read_only,
      keyed = {},
    }
    git.fetch(root, remote.name, pull.fetch, function(fetched, fetch_err)
      if not fetched then
        return fail('Could not fetch the pull request', fetch_err)
      end
      git.merge_base(root, pull.base_sha, head, function(base, base_err)
        if not base then return fail('No merge base', base_err) end
        s.merge_base = base
        git.files(root, base, head, function(files, files_err)
          if not files then
            return fail('Could not list the changed files', files_err)
          end
          local paths, read = {}, {}
          for _, file in ipairs(files) do
            file.kind = triage.classify(file.path, file.attrs)
            file.risk = file.kind == 'source' and triage.risk(file.path) or 0
            paths[#paths + 1] = file.path
            if file.kind ~= 'generated' then read[#read + 1] = file end
          end
          s.files, s.buckets = files, triage.buckets(files)
          load_hunks(s, read, function()
            git.blobs(root, head, paths, function(blobs, blob_err)
              if not blobs then
                return fail('Could not read the files', blob_err)
              end
              for _, file in ipairs(files) do
                file.blob = blobs[file.path]
              end
              worktree(s, function(made, tree_err)
                if not made then
                  return fail('Could not make the worktree', tree_err)
                end
                -- Before any buffer of it opens
                untrusted.hold(s.worktree, function() M.ask_trust(s) end)
                local loaded, state = pcall(store.load, remote, pull.id)
                if not loaded then
                  untrusted.forget(s.worktree)
                  return fail('Could not read the review', state)
                end
                s.state = state
                session, opening = s, false
                autocmds(s)
                diff.on_buffer(M.on_diff_buffer)
                load_forge(s, function()
                  save(s)
                  M.show()
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

--- The keys of a review's diff buffers: `{ mode, lhs, rhs, desc }`
---@return table[]
local function keys()
  local function current_mark()
    local path = diff.locate(vim.api.nvim_get_current_buf())
    if path then M.mark(path) end
  end
  return {
    { 'n', '<localleader>c', function() M.comment() end, 'Comment' },
    { 'x', '<localleader>c', function() M.comment() end, 'Comment on Lines' },
    {
      { 'n', 'x' },
      '<localleader>s',
      function() M.comment({ suggest = true }) end,
      'Suggest a Change',
    },
    { 'n', '<localleader>r', M.reply, 'Reply to Thread' },
    { 'n', '<localleader>R', M.toggle_resolve, 'Toggle Resolving Thread' },
    { 'n', '<localleader>m', current_mark, 'Mark File Reviewed' },
    {
      'n',
      '<localleader>k',
      function() M.ai_action('keep') end,
      'Keep AI Draft',
    },
    {
      'n',
      '<localleader>e',
      function() M.ai_action('edit') end,
      'Edit Draft',
    },
    {
      'n',
      '<localleader>x',
      function() M.ai_action('drop') end,
      'Drop Draft',
    },
    { 'n', ']a', function() M.jump_ai(1) end, 'Next Pending AI Draft' },
    { 'n', '[a', function() M.jump_ai(-1) end, 'Prev Pending AI Draft' },
  }
end

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
  local s = session
  if not s then return end
  drafts.draw(bufnr, path, side, s.state, s.threads)
  if not s.keyed[bufnr] then
    s.keyed[bufnr] = true
    local map = require('util.plugin').safe_keymap_set
    for _, key in ipairs(keys()) do
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
  local s = need()
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

--- Where the cursor is in the review's diff
---@return DyReviewSession? s
---@return string? path
---@return DyReviewSide? side
---@return integer line
local function here()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local s = need()
  if not s then return nil, nil, nil, line end
  local path, side = diff.locate(vim.api.nvim_get_current_buf())
  if not path then
    notify('Not in the diff of the review', WARN)
    return nil, nil, nil, line
  end
  return s, path, side, line
end

--- Call `cb` with the hunks of `path`, read now when they were left out
---@param s DyReviewSession
---@param path string
---@param cb fun(hunks: DyReviewHunks)
local function with_hunks(s, path, cb)
  if s.hunks[path] then return cb(s.hunks[path]) end
  local file = file_of(s, path)
  load_hunks(s, { file or { path = path } }, function(err)
    if not s.hunks[path] then
      return notify(
        ('Could not read the diff of %s: %s'):format(path, err or '?'),
        ERROR
      )
    end
    cb(s.hunks[path])
  end)
end

---@type integer
local editors = 0

--- A Markdown float to write a comment in; `:w` hands its lines to `on_save`
--- and closes it. `:q` on unsaved text is refused as for any file.
---@param title string
---@param lines string[]
---@param on_save fun(lines: string[])
local function editor(title, lines, on_save)
  editors = editors + 1
  local bufnr = vim.api.nvim_create_buf(false, false)
  vim.api.nvim_buf_set_name(bufnr, ('dyreview://draft/%d'):format(editors))
  vim.bo[bufnr].buftype = 'acwrite'
  vim.bo[bufnr].bufhidden = 'wipe'
  vim.bo[bufnr].swapfile = false
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modified = false
  vim.bo[bufnr].filetype = 'markdown'
  local width = math.max(math.min(80, vim.o.columns - 4), 20)
  local win = vim.api.nvim_open_win(bufnr, true, {
    relative = 'cursor',
    row = 1,
    col = 0,
    width = width,
    height = 10,
    border = 'rounded',
    title = (' %s (:w saves) '):format(title),
    title_pos = 'center',
  })
  vim.api.nvim_create_autocmd('BufWriteCmd', {
    buffer = bufnr,
    callback = function()
      local text = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
      vim.bo[bufnr].modified = false
      if vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      if vim.trim(table.concat(text, '\n')) == '' then
        return notify('Nothing written: no draft saved')
      end
      on_save(text)
    end,
  })
end

--- The body and the suggested lines of an editor's text
---@param lines string[]
---@return string body
---@return string[]? suggestion
local function parse(lines)
  local body, suggestion, inside = {}, nil, false
  for _, line in ipairs(lines) do
    if not inside and not suggestion and line:match('^```suggestion%s*$') then
      inside, suggestion = true, {}
    elseif inside and line:match('^```%s*$') then
      inside = false
    elseif inside then
      suggestion[#suggestion + 1] = line
    else
      body[#body + 1] = line
    end
  end
  return vim.trim(table.concat(body, '\n')), suggestion
end

--- Write a draft on the line or the lines under the cursor
---@param opts? { suggest?: boolean } Start from the lines as a suggestion
function M.comment(opts)
  opts = opts or {}
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local start_line ---@type integer?
  if vim.fn.mode():match('^[vV\22]') then
    local other = vim.fn.line('v')
    start_line, line = math.min(other, line), math.max(other, line)
    if start_line == line then start_line = nil end
    vim.cmd('normal! \27')
  end
  if opts.suggest and side ~= 'new' then
    return notify('A suggestion replaces lines of the new side', WARN)
  end
  local bufnr = vim.api.nvim_get_current_buf()
  with_hunks(s, path, function(hunks)
    local fields = { path = path, side = side, line = line }
    fields.start_line = start_line
    if not drafts.in_hunk(hunks, side, line, start_line) then
      notify(
        ('Outside the diff: sent as a file comment naming line %d'):format(line),
        WARN
      )
      fields.file_level = true
    end
    local initial = {}
    if opts.suggest then
      local first = start_line or line
      initial = { '', '```suggestion' }
      vim.list_extend(
        initial,
        vim.api.nvim_buf_get_lines(bufnr, first - 1, line, false)
      )
      table.insert(initial, '```')
    end
    editor('Comment', initial, function(text)
      if s ~= session then return notify('The review was closed', WARN) end
      fields.body, fields.suggestion = parse(text)
      drafts.add(s.state, fields)
      changed(s)
    end)
  end)
end

--- The thread on the cursor's line
---@param s DyReviewSession
---@param path string
---@param side DyReviewSide
---@param line integer
---@return DyReviewThread?
local function thread_at(s, path, side, line)
  for _, thread in ipairs(s.threads) do
    if
      thread.path == path
      and thread.side == side
      and thread.line
      and line >= (thread.start_line or thread.line)
      and line <= thread.line
    then
      return thread
    end
  end
end

--- Reply to the thread under the cursor
function M.reply()
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local thread = thread_at(s, path, side, line)
  if not thread then return notify('No thread on this line', WARN) end
  editor('Reply', {}, function(text)
    if s ~= session then return end
    local body = parse(text)
    drafts.add(s.state, {
      path = path,
      side = side,
      line = thread.line,
      body = body,
      reply_to = thread.id,
    })
    changed(s)
  end)
end

--- Resolve the thread under the cursor with the review, or take that back
function M.toggle_resolve()
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local thread = thread_at(s, path, side, line)
  if not thread then return notify('No thread on this line', WARN) end
  for i, draft in ipairs(s.state.drafts) do
    if
      draft.reply_to == thread.id
      and draft.origin == 'user'
      and not draft.posted
    then
      draft.resolve = not draft.resolve
      if not draft.resolve and draft.body == '' then
        table.remove(s.state.drafts, i)
      end
      notify(draft.resolve and 'Resolves with the review' or 'Left open')
      return changed(s)
    end
  end
  if thread.resolved then return notify('The thread is resolved already') end
  drafts.add(s.state, {
    path = path,
    side = side,
    line = thread.line,
    body = '',
    reply_to = thread.id,
    resolve = true,
  })
  notify('Resolves with the review')
  changed(s)
end

--- The draft on the cursor's line, an AI one first
---@param s DyReviewSession
---@param path string
---@param side DyReviewSide
---@param line integer
---@return DyReviewDraft?
local function draft_at(s, path, side, line)
  local found
  for _, draft in ipairs(s.state.drafts) do
    if
      draft.path == path
      and draft.side == side
      and not draft.posted
      and line >= (draft.start_line or draft.line)
      and line <= draft.line
      and (not found or draft.origin == 'ai')
    then
      found = draft
    end
  end
  return found
end

--- Keep, edit or drop the draft under the cursor
---@param action 'keep'|'edit'|'drop'
function M.ai_action(action)
  local s, path, side, line = here()
  if not (s and path and side) then return end
  local draft = draft_at(s, path, side, line)
  if not draft then return notify('No draft on this line', WARN) end
  if action == 'edit' then
    if draft.origin == 'forge' then
      return notify('A draft pending on the forge cannot be edited here', WARN)
    end
    return editor('Edit', vim.split(draft.body, '\n'), function(text)
      local ok, why = drafts.set_body(draft, (parse(text)))
      if not ok then return notify(why or 'Cannot edit', WARN) end
      if s == session then changed(s) end
    end)
  end
  local ok, why =
    drafts.set_state(draft, action == 'keep' and 'kept' or 'dropped')
  if not ok then return notify(why or 'Cannot change the draft', WARN) end
  changed(s)
end

--- Move to the next (1) or previous (-1) pending AI draft, in this file or
--- in the next file that has one
---@param dir 1|-1
function M.jump_ai(dir)
  local s = need()
  if not s then return end
  local here_path, here_side = diff.locate(vim.api.nvim_get_current_buf())
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local order, n = {}, 0 ---@type table<string, integer>, integer
  for _, bucket in ipairs(s.buckets) do
    for _, file in ipairs(bucket.files) do
      n = n + 1
      order[file.path] = n
    end
  end
  local list = vim.tbl_filter(
    function(d) return d.origin == 'ai' and d.state == 'pending' end,
    s.state.drafts
  )
  table.sort(list, function(a, b)
    local pa, pb = order[a.path] or math.huge, order[b.path] or math.huge
    if pa ~= pb then return pa < pb end
    return a.line < b.line
  end)
  if dir < 0 then list = vim.fn.reverse(list) end
  local pos = order[here_path] or 0
  for _, draft in ipairs(list) do
    local p = order[draft.path] or math.huge
    local ahead = dir > 0 and (p > pos or (p == pos and draft.line > line))
      or dir < 0 and (p < pos or (p == pos and draft.line < line))
    if ahead then
      if draft.path == here_path and draft.side == here_side then
        return vim.api.nvim_win_set_cursor(0, { draft.line, 0 })
      end
      s.jump = { path = draft.path, side = draft.side, line = draft.line }
      return M.show(draft.path)
    end
  end
  notify('No pending AI draft that way')
end

--- Mark `path` reviewed at its blob, or take the mark back
---@param path string
function M.mark(path)
  local s = need()
  if not s then return end
  local file = file_of(s, path)
  if not file then return end
  local blob = file.blob or ''
  s.state.reviewed[path] = s.state.reviewed[path] ~= blob and blob or nil
  changed(s)
end

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
      if item.line and session then
        session.jump = { path = item.path, side = item.side, line = item.line }
      end
      M.show(item.path)
    end,
  })
end

--- Every draft, with its origin and state
function M.list_drafts()
  local s = need()
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
  local s = need()
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
  rev_parse(s.root, s.refs .. 'reviewed', function(reviewed)
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

--- Pull requests of every forge remote: `fn(remote, adapter, done(list))`
---@param fn fun(remote: DyForgeRemote, adapter: DyReviewForge, done: fun(found: table[]))
---@param cb fun(found: table[]) `{ remote, pull }` each
local function each_forge(fn, cb)
  M.repo_root(function(root, err)
    if not root then return notify('Cannot review here: ' .. err, ERROR) end
    remotes(root, function(list)
      if #list == 0 then return notify('No remote on a known forge', WARN) end
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
    end)
  end)
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
              M.FORGE_NAMES[item.remote.kind] or item.remote.kind
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
        if item then M.open(item.remote, item.pull) end
      end,
    })
  end)
end

--- Review the pull request of the current branch, asking when two forges
--- have one
function M.branch()
  require('util.forge').branch(start_dir(), function(branch)
    if not branch then
      return notify('Detached HEAD: no branch to review', WARN)
    end
    each_forge(function(remote, adapter, done)
      adapter.for_branch(remote, branch, function(pull, err)
        if err then notify(('%s: %s'):format(remote.name, err), WARN) end
        done(pull and { { remote = remote, pull = pull } } or {})
      end)
    end, function(found)
      if #found == 0 then return notify('No pull request for ' .. branch) end
      if #found == 1 then return M.open(found[1].remote, found[1].pull) end
      vim.ui.select(found, {
        prompt = 'Review which pull request?',
        format_item = function(item)
          return ('%s !%s %s'):format(
            item.remote.name,
            item.pull.id,
            item.pull.title
          )
        end,
      }, function(item)
        if item then M.open(item.remote, item.pull) end
      end)
    end)
  end)
end

--- End the review: diff, panel and keys go, the refs but `reviewed` are
--- deleted, and the worktree is removed unless git refuses or a buffer there
--- has unsaved changes. A worktree kept stays held.
function M.close()
  local s = need()
  if not s then return end
  session = nil
  pcall(vim.api.nvim_del_augroup_by_name, 'dy_review')
  diff.close()
  panel.close(s)
  local unsaved = 0
  for bufnr in pairs(s.keyed) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, key in ipairs(keys()) do
        pcall(vim.keymap.del, key[1], key[2], { buffer = bufnr })
      end
    end
  end
  local dir = vim.uv.fs_realpath(s.worktree) or s.worktree
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if vim.startswith(vim.uv.fs_realpath(name) or name, dir .. '/') then
      if vim.bo[bufnr].modified then
        unsaved = unsaved + 1
      else
        pcall(vim.api.nvim_buf_delete, bufnr, {})
      end
    end
  end
  git.delete_refs(s.root, s.refs, { s.refs .. 'reviewed' }, function(_, err)
    if err then notify('Could not delete the review refs: ' .. err, WARN) end
  end)
  if unsaved > 0 then
    return notify(
      ('Kept the review worktree at %s: %d buffer(s) there have unsaved changes'):format(
        s.worktree,
        unsaved
      ),
      WARN
    )
  end
  git.worktree_remove(s.root, s.worktree, function(ok, err)
    if ok then return untrusted.forget(s.worktree) end
    notify(
      ('Kept the review worktree at %s: %s'):format(
        s.worktree,
        err or 'git refused to remove it'
      ),
      WARN
    )
  end)
end

--- `:DyReview [subcommand]`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1] or 'pick'
  if not vim.tbl_contains(M.SUBCOMMANDS, sub) then
    return notify('Unknown subcommand: ' .. sub, ERROR)
  end
  if sub == 'ai' or sub == 'submit' then
    return notify(('`:DyReview %s`: not yet'):format(sub))
  end
  local run = {
    pick = M.pick,
    branch = M.branch,
    since = M.since,
    drafts = M.list_drafts,
    close = M.close,
    trust = function()
      local s = need()
      if not s then return end
      if s.trusted then return notify('The review is trusted already') end
      M.ask_trust(s, true)
    end,
  }
  run[sub]()
end

return M
