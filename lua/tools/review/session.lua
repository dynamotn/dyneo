--- The review session: getting the pull request, holding its code, ending it
---
--- A session fetches the pull request into private refs, reads its change
--- from local git, checks the head out into a detached worktree under the
--- repository's `.worktrees/`, and loads its drafts, threads and pending
--- drafts. The worktree is held untrusted before any of its buffers opens:
--- no language server and no `.nvim` folder runs the author's code until the
--- reviewer says yes, once per pull request and head. The user's checkout,
--- index, branch and cwd are never touched.
local M = {}

local diff = require('tools.review.diff')
local forge = require('tools.review.forge')
local git = require('tools.review.git')
local panel = require('tools.review.panel')
local store = require('tools.review.store')
local triage = require('tools.review.triage')
local untrusted = require('util.untrusted')

local notify = require('util.notify').titled('Review')
local WARN, ERROR = vim.log.levels.WARN, vim.log.levels.ERROR

--- Where a pull request's refs live: `<prefix><forge>-<id>/{head,base,reviewed}`
M.REF_PREFIX = 'refs/dyneo/review/'

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
---@field threads_error? string Why the threads are not shown
---@field collapsed? table<DyReviewKind, boolean>
---@field panel_buf? integer
---@field panel_rows? table<integer, DyReviewPanelRow>
---@field keyed table<integer, boolean> Buffers given the review's keys
---@field jump? { path: string, side: DyReviewSide, line: integer }
---@field told_deps? boolean
---@field ci? DyReviewCi The CI state of the head, once asked for
---@field ci_loading? boolean A fetch of it is on its way
---@field ai_summary? string What the last AI pass said of the change
---@field ai_order? string[] The reading order of the last AI pass

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
function M.need()
  if not session then
    notify('No review is open: `:DyReview` picks one', WARN)
  end
  return session
end

--- Write the session's state; a failure is said and the state kept in memory
---@param s DyReviewSession
function M.save(s)
  local ok, err = pcall(store.save, s.remote, s.pull.id, s.state)
  if not ok then
    notify('Could not save the review: ' .. tostring(err), ERROR)
  end
end

--- Save, then draw the drafts and the panel again
---@param s DyReviewSession
function M.changed(s)
  M.save(s)
  diff.redraw()
  panel.refresh(s)
end

--- Whether a review is being sent, said when it is: closing or opening one
--- then would leave its drafts' posted marks to two states at once
---@return boolean
local function sending()
  local submit = package.loaded['tools.review.submit']
  if submit and submit.busy() then
    notify('A review is being sent: wait for it to finish', WARN)
    return true
  end
  return false
end

--- Whether `path`, resolved, lies under directory `dir`
---@param dir string
---@param path string
---@return boolean
function M.under(dir, path)
  dir = vim.uv.fs_realpath(dir) or dir
  path = vim.uv.fs_realpath(path) or path
  return vim.startswith(path, dir .. '/')
end

--- The directory the review starts from: the current file's, else the cwd
---@return string
function M.start_dir()
  local dir = vim.fn.expand('%:p:h')
  return vim.fn.isdirectory(dir) == 1 and dir or vim.uv.cwd() or '.'
end

--- Run git in `dir`, its first output line or nil
---@param dir string
---@param args string[]
---@param cb fun(out?: string)
function M.git_line(dir, args, cb)
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
  M.git_line(M.start_dir(), args, function(dir)
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
function M.rev_parse(dir, rev, cb)
  local args = { 'rev-parse', '--verify', '--quiet', '--end-of-options' }
  M.git_line(dir, vim.list_extend(args, { rev .. '^{commit}' }), cb)
end

--- The remote `branch` tracks in `dir`, nil when it tracks none
---@param dir string
---@param branch string
---@param cb fun(name?: string)
function M.tracked_remote(dir, branch, cb)
  M.git_line(dir, { 'config', '--get', 'branch.' .. branch .. '.remote' }, cb)
end

--- Every remote of `root` on a known forge, one per repository
---@param root string
---@param cb fun(remotes: DyForgeRemote[])
function M.remotes(root, cb)
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

--- Read the hunks of `files`, a few at a time
---@param s DyReviewSession
---@param files { path: string, old_path?: string }[]
---@param cb fun(err?: string)
function M.load_hunks(s, files, cb)
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
function M.file_of(s, path)
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
  M.rev_parse(s.worktree, 'HEAD', function(sha)
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
    if err or not threads then
      s.threads_error = err or 'no answer'
      notify('Could not read the threads: ' .. s.threads_error, WARN)
    end
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
      -- What a draft sent from here became is pending on the forge too:
      -- imported again, it would show and count twice
      local sent = {}
      for _, d in ipairs(kept) do
        local id = d.posted
          and s.adapter.import_id
          and s.adapter.import_id(d.posted)
        if id then sent[id] = true end
      end
      for _, d in ipairs(pending) do
        d.head = d.head or s.pull.head_sha
      end
      s.state.drafts = vim.list_extend(
        kept,
        vim.tbl_filter(function(d) return not sent[d.id] end, pending)
      )
    end
    done()
  end)
end

--- Say once that servers run without the project's dependencies, and let
--- the review's lock go when Neovim leaves
---@param s DyReviewSession
local function autocmds(s)
  local group = vim.api.nvim_create_augroup('dy_review', { clear = true })
  vim.api.nvim_create_autocmd('VimLeavePre', {
    group = group,
    callback = function() pcall(store.unlock, s.remote, s.pull.id) end,
  })
  vim.api.nvim_create_autocmd('LspAttach', {
    group = group,
    callback = function(args)
      if s ~= session or s.told_deps then return end
      if M.under(s.worktree, vim.api.nvim_buf_get_name(args.buf)) then
        s.told_deps = true
        notify(
          'Dependencies are not installed in the review worktree: some servers answer only in part'
        )
      end
    end,
  })
end

--- Whether review `s` is of pull request `id` of `remote`
---@param s DyReviewSession
---@param remote DyForgeRemote
---@param id string
---@return boolean
function M.same(s, remote, id)
  return s.remote.host == remote.host
    and s.remote.slug == remote.slug
    and s.pull.id == id
end

--- Open a review of `pull` on `remote`, or show the one already open. A
--- review of an older head of the same pull request is closed first.
---@param remote DyForgeRemote
---@param pull DyReviewPull
function M.open(remote, pull)
  if sending() then return end
  local review = require('tools.review')
  if session and M.same(session, remote, pull.id) then
    if session.pull.head_sha == pull.head_sha then return review.show() end
    notify(
      ('The pull request moved to %s: opening the new head'):format(
        pull.head_sha:sub(1, 7)
      )
    )
  end
  if opening then return notify('A review is already opening', WARN) end
  -- A head that cannot be fetched leaves no diff to read: say why, before
  -- any fetch would fail on it with a reason that names none
  if pull.unfetchable then
    return notify(pull.unfetchable .. ': nothing to show', WARN)
  end
  local adapter, why = forge.for_remote(remote)
  if not adapter then
    return notify(('%s: %s'):format(remote.kind, why or 'no adapter'), WARN)
  end
  opening = true
  local function fail(what, reason)
    opening = false
    notify(('%s: %s'):format(what, reason or 'unknown error'), ERROR)
  end
  local function start() M.start(remote, pull, adapter, fail) end
  if not session then return start() end
  -- The new head goes where the old one was: wait until it is gone
  if not M.close(start) then opening = false end
end

--- Get the pull request and make it the session; `fail` says why not
---@param remote DyForgeRemote
---@param pull DyReviewPull
---@param adapter DyReviewForge
---@param fail fun(what: string, reason?: string)
function M.start(remote, pull, adapter, fail)
  local review = require('tools.review')
  -- One Neovim at a time reviews a pull request: two would each send what
  -- the other sent
  local called, locked, lock_err = pcall(store.lock, remote, pull.id)
  if not (called and locked) then
    return fail('Not opened', called and lock_err or tostring(locked))
  end
  local give_up = fail
  fail = function(what, reason)
    pcall(store.unlock, remote, pull.id)
    give_up(what, reason)
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
          M.load_hunks(s, read, function()
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
                  return fail('Could not read the review', tostring(state))
                end
                s.state = state
                session, opening = s, false
                autocmds(s)
                diff.on_buffer(review.on_diff_buffer)
                load_forge(s, function()
                  M.save(s)
                  review.show()
                  -- Never waited for: the review is usable without it
                  require('tools.review.ci').load(s)
                end)
              end)
            end)
          end)
        end)
      end)
    end)
  end)
end

--- Buffers holding unsaved text of review `s`: its worktree's files, and
--- draft editors
---@param s DyReviewSession
---@return string[] names
local function unsaved(s)
  local names = {}
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    local name = vim.api.nvim_buf_get_name(bufnr)
    if
      vim.bo[bufnr].modified
      and (
        vim.startswith(name, 'dyreview://draft/') or M.under(s.worktree, name)
      )
    then
      names[#names + 1] = name
    end
  end
  return names
end

--- End the review: diff, panel and keys go, the refs but `reviewed` are
--- deleted, and the worktree is removed unless git refuses; a worktree kept
--- stays held. Nothing ends while a buffer of the review holds unsaved text.
---@param on_done? fun() Once the worktree is removed or kept
---@return boolean closed
function M.close(on_done)
  if sending() then return false end
  local s = M.need()
  if not s then return false end
  local names = unsaved(s)
  if #names > 0 then
    notify('Not closed: unsaved changes in ' .. table.concat(names, ', '), WARN)
    return false
  end
  session = nil
  pcall(vim.api.nvim_del_augroup_by_name, 'dy_review')
  pcall(store.unlock, s.remote, s.pull.id)
  diff.close()
  panel.close(s)
  local keys = require('tools.review.actions').keys()
  for bufnr in pairs(s.keyed) do
    if vim.api.nvim_buf_is_valid(bufnr) then
      for _, key in ipairs(keys) do
        pcall(vim.keymap.del, key[1], key[2], { buffer = bufnr })
      end
    end
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if M.under(s.worktree, vim.api.nvim_buf_get_name(bufnr)) then
      pcall(vim.api.nvim_buf_delete, bufnr, {})
    end
  end
  git.delete_refs(s.root, s.refs, { s.refs .. 'reviewed' }, function(_, err)
    if err then notify('Could not delete the review refs: ' .. err, WARN) end
  end)
  git.worktree_remove(s.root, s.worktree, function(ok, err)
    if ok then
      untrusted.forget(s.worktree)
    else
      notify(
        ('Kept the review worktree at %s: %s'):format(
          s.worktree,
          err or 'git refused to remove it'
        ),
        WARN
      )
    end
    if on_done then on_done() end
  end)
  return true
end

return M
