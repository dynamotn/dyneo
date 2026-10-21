--- A pull request's change, read from local git
---
--- Everything here asks `git` about objects already in the repository, never
--- the forge's diff API, so a pull request of any size reads the same. The
--- pull request is fetched into private refs first (`fetch`), and the rest
--- compares revisions of it.
---
--- Every function answers `cb(result?, err?)` on the main loop. A command that
--- failed, timed out, ran past its output cap or is not installed gives
--- `cb(nil, reason)`, never an empty list that reads as "nothing changed".
--- Paths come back from `-z` output, so a name with spaces, tabs or newlines
--- survives; paths go to git as literal pathspecs, so `*` and `[` in a name
--- are not patterns.
local M = {}

local sys = require('util.system')

--- The deadline of a local git command, in milliseconds
M.TIMEOUT = 30 * 1000

--- The deadline of `fetch`, in milliseconds: a large pull request is a large
--- download
M.FETCH_TIMEOUT = 2 * 60 * 1000

--- The output kept from a listing (`numstat`, names), in bytes
M.MAX_LIST_BYTES = 32 * 1024 * 1024

--- The output kept from the diff of one file, in bytes
M.MAX_DIFF_BYTES = 4 * 1024 * 1024

--- How many commands `interdiff`, `diff` and `blobs` run at once
M.CONCURRENCY = 4

--- Paths given to one `ls-tree`, to stay under the argument limit
M.BATCH = 500

---@class DyReviewHunks
---@field old integer[][] `{ first, last }` lines of the base side
---@field new integer[][] `{ first, last }` lines of the head side

--- Run git in `root`
---@param root string
---@param args string[]
---@param opts? DyRunOpts
---@param on_done fun(result: DyRunResult, err?: string)
local function run(root, args, opts, on_done)
  opts = vim.tbl_extend('force', {
    cwd = root,
    timeout = M.TIMEOUT,
    max_bytes = M.MAX_DIFF_BYTES,
  }, opts or {})
  -- Never wait on a credential prompt, and never take an optional lock a
  -- background read does not need
  opts.env = vim.tbl_extend(
    'force',
    { GIT_TERMINAL_PROMPT = '0', GIT_OPTIONAL_LOCKS = '0' },
    opts.env or {}
  )
  local cmd = { 'git', '--no-pager', '--literal-pathspecs' }
  vim.list_extend(cmd, args)
  sys.run(cmd, opts, function(result)
    local err
    if result.code ~= 0 or result.cut or result.timed_out or result.missing then
      -- Named by its command, past any `-c name=value`
      local command = args[1] == '-c' and args[3] or args[1]
      err = sys.failure(result, 'git ' .. (command or ''))
    end
    on_done(result, err)
  end)
end

--- Why `...` cannot go to git, nil when it can
---
--- A revision, remote, ref or directory starting with `-` would be read as
--- an option (`--output=<file>`, `--upload-pack=<cmd>`). `--end-of-options`
--- covers the commands that honour it; this covers the rest, and fails
--- closed with a reason.
---@param ... string?
---@return string?
local function refuse(...)
  for i = 1, select('#', ...) do
    local value = select(i, ...)
    if type(value) == 'string' and value:sub(1, 1) == '-' then
      return ('refusing "%s": it reads as a git option'):format(value)
    end
  end
end

--- Hand `cb` a refusal on the main loop, as `run` answers
---@param cb function
---@param ... any
local function answer(cb, ...)
  local args = vim.F.pack_len(...)
  vim.schedule(function() cb(vim.F.unpack_len(args)) end)
end

--- Split NUL-separated output, dropping the empty field after the last NUL
---@param out string
---@return string[]
local function split_nul(out)
  local fields = vim.split(out, '\0', { plain = true })
  if fields[#fields] == '' then table.remove(fields) end
  return fields
end

--- Run `jobs` commands at once and call `done` with their results in order,
--- or with the first error
---@param jobs fun(done: fun(result?: any, err?: string))[]
---@param done fun(results?: any[], err?: string)
local function all(jobs, done)
  local results, failed, pending = {}, nil, #jobs
  if pending == 0 then return done({}) end
  for i, job in ipairs(jobs) do
    job(function(result, err)
      results[i] = result
      failed = failed or err
      pending = pending - 1
      if pending == 0 then
        if failed then return done(nil, failed) end
        done(results)
      end
    end)
  end
end

--- Fetch `refspecs` from `remote` into this repository
---
--- `refspecs` bring objects (and may name private refs); the work tree and
--- the branches are not touched. No tags, and no prompt: a fetch that needs a
--- password fails with a reason instead of taking the terminal. Nor does
--- it fetch submodules (the pull request names their URLs), write
--- `FETCH_HEAD` over the user's, or start a gc in the background.
---@param root string
---@param remote string
---@param refspecs string[]
---@param cb fun(ok: boolean, err?: string)
function M.fetch(root, remote, refspecs, cb)
  local bad = refuse(remote)
  if bad then return answer(cb, false, bad) end
  local args = {
    '-c',
    'gc.auto=0',
    'fetch',
    '--no-tags',
    '--no-recurse-submodules',
    '--no-write-fetch-head',
    '--quiet',
    '--end-of-options',
    remote,
  }
  vim.list_extend(args, refspecs)
  run(root, args, {
    timeout = M.FETCH_TIMEOUT,
    max_bytes = 64 * 1024,
    detach = true,
    env = { GIT_TERMINAL_PROMPT = '0', GCM_INTERACTIVE = 'never' },
  }, function(_, err) cb(err == nil, err) end)
end

--- Set `ref` to `sha`
---@param root string
---@param ref string
---@param sha string
---@param cb fun(ok: boolean, err?: string)
function M.update_ref(root, ref, sha, cb)
  local bad = refuse(ref, sha)
  if bad then return answer(cb, false, bad) end
  run(
    root,
    { 'update-ref', '--end-of-options', ref, sha },
    { max_bytes = 64 * 1024 },
    function(_, err) cb(err == nil, err) end
  )
end

--- Delete the refs under `prefix` that are not in `keep`
---@param root string
---@param prefix string
---@param keep string[] Full ref names to leave alone
---@param cb fun(deleted?: string[], err?: string)
function M.delete_refs(root, prefix, keep, cb)
  local bad = refuse(prefix)
  if bad then return answer(cb, nil, bad) end
  run(
    root,
    { 'for-each-ref', '--format=%(refname)', '--end-of-options', prefix },
    { max_bytes = M.MAX_LIST_BYTES },
    function(listing, err)
      if err then return cb(nil, err) end
      local kept = {}
      for _, ref in ipairs(keep) do
        kept[ref] = true
      end
      local doomed = {}
      for ref in vim.gsplit(listing.stdout, '\n', { plain = true }) do
        if ref ~= '' and not kept[ref] then table.insert(doomed, ref) end
      end
      if #doomed == 0 then return cb({}) end
      table.sort(doomed)
      local script = {}
      for _, ref in ipairs(doomed) do
        table.insert(script, 'delete ' .. ref .. '\n')
      end
      run(root, { 'update-ref', '--stdin' }, {
        stdin = table.concat(script),
        max_bytes = 64 * 1024,
      }, function(_, delete_err)
        if delete_err then return cb(nil, delete_err) end
        cb(doomed)
      end)
    end
  )
end

--- The best common ancestor of `a` and `b`
---@param root string
---@param a string
---@param b string
---@param cb fun(sha?: string, err?: string)
function M.merge_base(root, a, b, cb)
  local bad = refuse(a, b)
  if bad then return answer(cb, nil, bad) end
  run(
    root,
    { 'merge-base', '--end-of-options', a, b },
    { max_bytes = 64 * 1024 },
    function(result, err)
      if err then
        -- Exit 1 with nothing to say is "no common ancestor"
        if result.code == 1 and vim.trim(result.stderr) == '' then
          err = ('%s and %s have no common ancestor'):format(a, b)
        end
        return cb(nil, err)
      end
      local sha = vim.trim(result.stdout)
      if sha == '' then return cb(nil, 'git merge-base printed nothing') end
      cb(sha)
    end
  )
end

--- Whether a `check-attr` value switches the attribute on
---@param value string
---@return boolean
local function attr_on(value)
  return value ~= 'unspecified' and value ~= 'unset' and value ~= 'false'
end

--- The `linguist-generated` / `linguist-vendored` attributes of `paths`, as
--- `head` has them
---
--- `--source` reads the attributes of that revision rather than of the
--- working tree, which is not the pull request's.
---@param root string
---@param head string
---@param paths string[]
---@param cb fun(attrs?: table<string, { generated: boolean, vendored: boolean }>, err?: string)
local function attributes(root, head, paths, cb)
  if #paths == 0 then return cb({}) end
  run(root, {
    'check-attr',
    '-z',
    '--source=' .. head,
    'linguist-generated',
    'linguist-vendored',
    '--stdin',
  }, {
    stdin = table.concat(paths, '\0') .. '\0',
    max_bytes = M.MAX_LIST_BYTES,
  }, function(result, err)
    if err then return cb(nil, err) end
    local fields = split_nul(result.stdout)
    local attrs = {}
    for i = 1, #fields - 2, 3 do
      local path, name, value = fields[i], fields[i + 1], fields[i + 2]
      local entry = attrs[path] or { generated = false, vendored = false }
      if name == 'linguist-generated' then entry.generated = attr_on(value) end
      if name == 'linguist-vendored' then entry.vendored = attr_on(value) end
      attrs[path] = entry
    end
    cb(attrs)
  end)
end

--- Line counts from `git diff --numstat -z -M`, by the path after the change
---@param out string
---@return table<string, { added: integer, removed: integer, binary: boolean }>
local function parse_numstat(out)
  local fields = split_nul(out)
  local counts = {}
  local i = 1
  while i <= #fields do
    local added, removed, path = fields[i]:match('^(%S+)\t(%S+)\t(.*)$')
    if not added then
      i = i + 1
    else
      -- A rename has an empty path here, then the old and the new path
      if path == '' then
        path = fields[i + 2]
        i = i + 3
      else
        i = i + 1
      end
      local binary = added == '-' and removed == '-'
      counts[path] = {
        added = tonumber(added) or 0,
        removed = tonumber(removed) or 0,
        binary = binary,
      }
    end
  end
  return counts
end

--- The status letter of each changed path from `git diff --name-status -z -M`
---@param out string
---@return { status: string, path: string, old_path?: string }[]
local function parse_name_status(out)
  local fields = split_nul(out)
  local entries = {}
  local i = 1
  while i <= #fields do
    local code = fields[i]:sub(1, 1)
    if code == 'R' or code == 'C' then
      table.insert(entries, {
        status = code == 'R' and 'R' or 'A',
        old_path = fields[i + 1],
        path = fields[i + 2],
      })
      i = i + 3
    else
      -- A type change and anything unforeseen read as a modification
      local status = (code == 'A' or code == 'D') and code or 'M'
      table.insert(entries, { status = status, path = fields[i + 1] })
      i = i + 2
    end
  end
  return entries
end

--- The files changed between `base` and `head`
---
--- Without `kind` and `risk`: the caller sets those with `tools.review.triage`,
--- for which `attrs` carries what the repository says about generated and
--- vendored files.
---@param root string
---@param base string
---@param head string
---@param cb fun(files?: table[], err?: string) DyReviewFile without kind and risk
function M.files(root, base, head, cb)
  local bad = refuse(base, head)
  if bad then return answer(cb, nil, bad) end
  local function diff_job(flag)
    return function(done)
      run(
        root,
        {
          'diff',
          '--no-ext-diff',
          flag,
          '-z',
          '-M',
          '--end-of-options',
          base,
          head,
          '--',
        },
        { max_bytes = M.MAX_LIST_BYTES },
        function(result, err) done(result and result.stdout, err) end
      )
    end
  end
  all({ diff_job('--numstat'), diff_job('--name-status') }, function(out, err)
    if err or not out then return cb(nil, err) end
    local counts = parse_numstat(out[1])
    local entries = parse_name_status(out[2])
    local paths = {}
    for _, entry in ipairs(entries) do
      if entry.status ~= 'D' then table.insert(paths, entry.path) end
    end
    attributes(root, head, paths, function(attrs, attr_err)
      if not attrs then return cb(nil, attr_err) end
      local files = {}
      for _, entry in ipairs(entries) do
        local count = counts[entry.path]
          or { added = 0, removed = 0, binary = false }
        local attr = attrs[entry.path]
          or { generated = false, vendored = false }
        table.insert(files, {
          path = entry.path,
          old_path = entry.old_path,
          status = entry.status,
          added = count.added,
          removed = count.removed,
          binary = count.binary,
          attrs = attr,
        })
      end
      cb(files)
    end)
  end)
end

--- The blob id of each of `paths` in `rev`; a path `rev` lacks is left out
---@param root string
---@param rev string
---@param paths string[]
---@param cb fun(blobs?: table<string, string>, err?: string)
function M.blobs(root, rev, paths, cb)
  local bad = refuse(rev)
  if bad then return answer(cb, nil, bad) end
  local batches = {}
  for i = 1, #paths, M.BATCH do
    table.insert(batches, vim.list_slice(paths, i, i + M.BATCH - 1))
  end
  local blobs, failed = {}, nil
  sys.each(batches, M.CONCURRENCY, function(batch, done)
    local args = { 'ls-tree', '-z', '--end-of-options', rev, '--' }
    vim.list_extend(args, batch)
    run(root, args, { max_bytes = M.MAX_LIST_BYTES }, function(result, err)
      failed = failed or err
      for _, record in ipairs(err and {} or split_nul(result.stdout)) do
        local id, path = record:match('^%S+ %S+ (%x+)\t(.*)$')
        if id then blobs[path] = id end
      end
      done()
    end)
  end, function()
    if failed then return cb(nil, failed) end
    cb(blobs)
  end)
end

--- The lines changed in `path` between `base` and `head`, on each side
---
--- What a comment may sit on: a line outside every range is not part of the
--- change.
---@param root string
---@param base string
---@param head string
---@param path string
---@param old_path? string Where a renamed file was, so only its real change shows
---@param cb? fun(hunks?: DyReviewHunks, err?: string)
function M.hunks(root, base, head, path, old_path, cb)
  if type(old_path) == 'function' then
    cb, old_path = old_path, nil
  end
  ---@cast cb fun(hunks?: DyReviewHunks, err?: string)
  local bad = refuse(base, head)
  if bad then return answer(cb, nil, bad) end
  -- Both names, or the diff of the new one alone is the whole file added
  local args = {
    'diff',
    '--no-color',
    '--no-ext-diff',
    '-U0',
    '-M',
    '--end-of-options',
    base,
    head,
    '--',
  }
  if old_path and old_path ~= path then table.insert(args, old_path) end
  table.insert(args, path)
  run(root, args, {}, function(result, err)
    if err then return cb(nil, err) end
    local hunks = { old = {}, new = {} }
    for line in vim.gsplit(result.stdout, '\n', { plain = true }) do
      local os, oc, ns, nc = line:match('^@@ %-(%d+),?(%d*) %+(%d+),?(%d*) @@')
      if os then
        -- A missing count is 1; a count of 0 is a pure insertion or deletion
        -- on that side, with no line to name
        oc = oc == '' and 1 or tonumber(oc)
        nc = nc == '' and 1 or tonumber(nc)
        os, ns = tonumber(os), tonumber(ns)
        if oc > 0 then table.insert(hunks.old, { os, os + oc - 1 }) end
        if nc > 0 then table.insert(hunks.new, { ns, ns + nc - 1 }) end
      end
    end
    cb(hunks)
  end)
end

--- The stable patch id of the change to `path`, nil when it is unchanged
---@param root string
---@param base string
---@param head string
---@param path string
---@param cb fun(id?: string, err?: string)
local function patch_id(root, base, head, path, cb)
  -- No context: lines around the change that a rebase moved are not an edit
  run(root, {
    'diff',
    '--no-color',
    '--no-ext-diff',
    '-U0',
    '--end-of-options',
    base,
    head,
    '--',
    path,
  }, {}, function(diff, err)
    if err then return cb(nil, err) end
    if diff.stdout == '' then return cb(nil, nil) end
    run(
      root,
      { 'patch-id', '--stable' },
      { stdin = diff.stdout, max_bytes = 64 * 1024 },
      function(result, id_err)
        if id_err then return cb(nil, id_err) end
        cb(result.stdout:match('^(%x+)'))
      end
    )
  end)
end

--- The paths whose change differs between two versions of a pull request
---
--- Each side is `base..head`; the same file changed the same way on a new
--- base (a rebase) has the same patch id and is not reported. A path changed
--- on one side only is.
---@param root string
---@param base_old string
---@param head_old string
---@param base_new string
---@param head_new string
---@param cb fun(paths?: string[], err?: string) Sorted
function M.interdiff(root, base_old, head_old, base_new, head_new, cb)
  local bad = refuse(base_old, head_old, base_new, head_new)
  if bad then return answer(cb, nil, bad) end
  local function names(base, head)
    return function(done)
      run(
        root,
        {
          'diff',
          '--name-only',
          '-z',
          '--no-renames',
          '--no-ext-diff',
          '--end-of-options',
          base,
          head,
          '--',
        },
        { max_bytes = M.MAX_LIST_BYTES },
        function(result, err) done(result and split_nul(result.stdout), err) end
      )
    end
  end
  all(
    { names(base_old, head_old), names(base_new, head_new) },
    function(lists, err)
      if not lists then return cb(nil, err) end
      local seen, paths = {}, {}
      for _, list in ipairs(lists) do
        for _, path in ipairs(list) do
          if not seen[path] then
            seen[path] = true
            table.insert(paths, path)
          end
        end
      end
      table.sort(paths)
      local changed, failed = {}, nil
      sys.each(paths, M.CONCURRENCY, function(path, done)
        if failed then return done() end
        patch_id(root, base_old, head_old, path, function(old_id, old_err)
          if old_err then
            failed = failed or old_err
            return done()
          end
          patch_id(root, base_new, head_new, path, function(new_id, new_err)
            failed = failed or new_err
            if not new_err and old_id ~= new_id then
              table.insert(changed, path)
            end
            done()
          end)
        end)
      end, function()
        if failed then return cb(nil, failed) end
        table.sort(changed)
        cb(changed)
      end)
    end
  )
end

--- The diff of each of `paths` between `base` and `head`, at most `max_bytes`
--- of them together
---
--- Paths are taken in order and one that does not fit is left out of the
--- answer, so `cut` says something is missing and a path absent from `diffs`
--- is the one that is. A file with no change has an empty diff.
---@param root string
---@param base string
---@param head string
---@param paths (string|{ path: string, old_path?: string })[] A renamed file as `{ path, old_path }`, so only its real change shows
---@param max_bytes integer
---@param cb fun(diffs?: table<string, string>, err?: string, cut: boolean)
function M.diff(root, base, head, paths, max_bytes, cb)
  local bad = refuse(base, head)
  if bad then return answer(cb, nil, bad, false) end
  local names = {}
  for i, entry in ipairs(paths) do
    names[i] = type(entry) == 'table' and (entry.path or entry[1]) or entry
  end
  local results, failed = {}, nil
  sys.each(paths, M.CONCURRENCY, function(entry, done)
    if failed then return done() end
    local path = type(entry) == 'table' and (entry.path or entry[1]) or entry
    local old_path = type(entry) == 'table' and entry.old_path or nil
    local args = {
      'diff',
      '--no-color',
      '--no-ext-diff',
      '-M',
      '--end-of-options',
      base,
      head,
      '--',
    }
    if old_path and old_path ~= path then table.insert(args, old_path) end
    table.insert(args, path)
    run(root, args, {
      -- One byte past the budget tells that this file alone overflows it
      max_bytes = max_bytes + 1,
    }, function(result, err)
      if result.cut and not result.timed_out and not result.missing then
        -- Too big for the budget on its own: left out below, not a failure
        results[path] = { too_big = true }
      elseif err then
        failed = failed or err
      else
        results[path] = { text = result.stdout }
      end
      done()
    end)
  end, function()
    if failed then return cb(nil, failed, false) end
    local diffs, used, cut = {}, 0, false
    for _, path in ipairs(names) do
      local entry = results[path]
      if entry and entry.text and used + #entry.text <= max_bytes then
        diffs[path] = entry.text
        used = used + #entry.text
      else
        cut = true
      end
    end
    cb(diffs, nil, cut)
  end)
end

--- Add a detached worktree of `rev` at `dir`
---@param root string
---@param dir string
---@param rev string
---@param cb fun(ok: boolean, err?: string)
function M.worktree_add(root, dir, rev, cb)
  local bad = refuse(dir, rev)
  if bad then return answer(cb, false, bad) end
  run(
    root,
    { 'worktree', 'add', '--detach', '--end-of-options', dir, rev },
    { max_bytes = 64 * 1024, timeout = M.FETCH_TIMEOUT },
    function(_, err) cb(err == nil, err) end
  )
end

--- Remove the worktree at `dir`; git refuses one with changes, and so does
--- this: there is no `--force`
---@param root string
---@param dir string
---@param cb fun(ok: boolean, err?: string)
function M.worktree_remove(root, dir, cb)
  local bad = refuse(dir)
  if bad then return answer(cb, false, bad) end
  run(
    root,
    { 'worktree', 'remove', '--end-of-options', dir },
    { max_bytes = 64 * 1024 },
    function(_, err) cb(err == nil, err) end
  )
end

return M
