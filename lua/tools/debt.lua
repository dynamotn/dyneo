--- Technical debt you can see aging: the TODO, FIXME, HACK and XXX comments
--- of a project, oldest first, with their age and author from `git blame`
---
--- The markers are found by one `git grep` with todo-comments.nvim's own
--- search pattern (a keyword followed by a colon), over the tracked and
--- untracked files git does not ignore. Each file with markers is blamed
--- once, for its marked lines only, a few files at a time. A line not yet
--- committed is 0 days old. Outside a git repository the markers are still
--- listed, from `git grep --no-index`, without ages.
---
--- What one run found is kept per project for the session, keyed by HEAD and
--- the output of `git status`, so asking again is instant until a commit or a
--- change to the set of dirty files.
---
--- Notifications name paths and line numbers only; the text of a comment
--- goes to the quickfix list alone.
local M = {}

local notify = require('util.notify').titled('Debt')

--- The keywords listed, as todo-comments.nvim highlights them
M.KEYWORDS = { 'TODO', 'FIXME', 'HACK', 'XXX' }

--- Files blamed; markers in the files past it are listed without an age
M.MAX_FILES = 500

--- Files blamed at a time
M.JOBS = 4

--- Milliseconds one git command may take
M.TIMEOUT = 60 * 1000

--- Output kept of `git grep`, and of one `git blame`
M.MAX_BYTES = 8 * 1024 * 1024

---@class DyDebtEntry
---@field file string Relative to the project root
---@field lnum integer
---@field keyword string
---@field text string The comment after the keyword
---@field time? integer When the line was written; nil when not known
---@field author? string
---@field mail? string Lower case, without the angle brackets
---@field uncommitted? boolean

---@class DyDebtScan
---@field entries DyDebtEntry[]
---@field git boolean
---@field reason? string Why there are no ages

--- Scans of each project root: `key` is HEAD and `git status`
---@type table<string, { key: string, scan: DyDebtScan }>
M.cache = {}

--- The extended regex `git grep` searches with
---@return string
function M.pattern()
  return ('(^|[^[:alnum:]_])(%s):'):format(table.concat(M.KEYWORDS, '|'))
end

--- The first marker of `line`: its keyword and the comment after it
---@param line string
---@return string? keyword
---@return string? text
function M.marker(line)
  local best, keyword, text
  for _, kw in ipairs(M.KEYWORDS) do
    local at, rest = line:match('()%f[%w_]' .. kw .. ':(.*)$')
    if at and (not best or at < best) then
      best, keyword, text = at, kw, rest
    end
  end
  if not keyword then return nil end
  -- Closing a block comment is not part of what it says
  text = vim.trim(text):gsub('%s*%*/$', ''):gsub('%s*%-%->$', '')
  return keyword, text
end

--- The markers in the output of `git grep -n -z`: `path\0lnum\0line` per hit
---@param text string
---@return DyDebtEntry[]
function M.parse_grep(text)
  local entries = {}
  for record in vim.gsplit(text, '\n', { trimempty = true }) do
    local file, lnum, line = record:match('^([^%z]+)%z(%d+)%z(.*)$')
    local keyword, comment = M.marker(line or '')
    if file and keyword then
      table.insert(entries, {
        file = file,
        lnum = tonumber(lnum),
        keyword = keyword,
        text = comment,
      })
    end
  end
  return entries
end

---@class DyBlameLine
---@field time? integer
---@field author? string
---@field mail? string
---@field uncommitted boolean

--- Who wrote each line in the output of `git blame --porcelain`, by line
---@param text string
---@return table<integer, DyBlameLine>
function M.parse_blame(text)
  local commits, lines, current = {}, {}, nil
  for line in vim.gsplit(text, '\n', { trimempty = true }) do
    local sha, final = line:match('^(%x+) %d+ (%d+)')
    if sha and (#sha == 40 or #sha == 64) then
      commits[sha] = commits[sha] or {}
      current = commits[sha]
      lines[tonumber(final)] = sha
    elseif current and line:sub(1, 1) ~= '\t' then
      local key, value = line:match('^(%S+) (.*)$')
      if key then current[key] = value end
    end
  end
  local blamed = {}
  for lnum, sha in pairs(lines) do
    local info = commits[sha]
    if sha:match('^0+$') then
      blamed[lnum] = { uncommitted = true }
    else
      blamed[lnum] = {
        time = tonumber(info['author-time']),
        author = info.author,
        mail = (info['author-mail'] or '')
          :gsub('^<', '')
          :gsub('>$', '')
          :lower(),
        uncommitted = false,
      }
    end
  end
  return blamed
end

--- The age of something written at `time`, at `now`, as `3y 2m`, `5m` or
--- `12d`: calendar months, so a year to the day is `1y 0m`
---@param time integer
---@param now integer
---@return string
function M.age(time, now)
  local from, to = os.date('*t', time), os.date('*t', now)
  local months = (to.year - from.year) * 12 + to.month - from.month
  if to.day < from.day then months = months - 1 end
  if months < 1 then
    return ('%dd'):format(math.floor(math.max(0, now - time) / 86400))
  end
  if months < 12 then return ('%dm'):format(months) end
  return ('%dy %dm'):format(math.floor(months / 12), months % 12)
end

--- The age of `entry` in seconds at `now`, nil when not known
---@param entry DyDebtEntry
---@param now integer
---@return integer?
local function seconds(entry, now)
  if entry.uncommitted then return 0 end
  if entry.time then return now - entry.time end
  return nil
end

--- `entries`, the oldest first and those of no known age last
---@param entries DyDebtEntry[]
---@param now integer
---@return DyDebtEntry[]
function M.sort(entries, now)
  local sorted = vim.list_slice(entries)
  table.sort(sorted, function(a, b)
    local x, y = seconds(a, now), seconds(b, now)
    if x ~= y then
      if not x or not y then return x ~= nil end
      return x > y
    end
    if a.file ~= b.file then return a.file < b.file end
    return a.lnum < b.lnum
  end)
  return sorted
end

--- The text of the quickfix item of `entry`
---@param entry DyDebtEntry
---@param now integer
---@return string
function M.label(entry, now)
  local age = seconds(entry, now)
  local parts = { ('[%s]'):format(entry.keyword) }
  if age then
    parts[1] = parts[1] .. ' ' .. M.age(now - age, now)
    table.insert(
      parts,
      entry.uncommitted and 'not committed' or entry.author or '?'
    )
  end
  table.insert(parts, entry.text)
  return table.concat(parts, ' · ')
end

--- One line on `entries`: the count per keyword, the median age, the oldest;
--- paths and line numbers only, never the text
---@param entries DyDebtEntry[] Sorted by `M.sort`
---@param now integer
---@return string
function M.summary(entries, now)
  local counts, ages = {}, {}
  for _, entry in ipairs(entries) do
    counts[entry.keyword] = (counts[entry.keyword] or 0) + 1
    local age = seconds(entry, now)
    if age then table.insert(ages, age) end
  end
  local per = {}
  for _, kw in ipairs(M.KEYWORDS) do
    if counts[kw] then table.insert(per, ('%s %d'):format(kw, counts[kw])) end
  end
  local line = ('%d markers (%s)'):format(#entries, table.concat(per, ', '))
  if #ages > 0 then
    table.sort(ages)
    local mid = math.floor((#ages + 1) / 2)
    local median = #ages % 2 == 1 and ages[mid]
      or math.floor((ages[mid] + ages[mid + 1]) / 2)
    local oldest = entries[1]
    line = ('%s; median age %s; oldest %s at %s:%d'):format(
      line,
      M.age(now - median, now),
      M.age(now - ages[#ages], now),
      oldest.file,
      oldest.lnum
    )
  end
  return line
end

--- The entries of `scan` that `args` keep: a keyword, `mine`, or both
---@param scan DyDebtScan
---@param args string[]
---@param email? string Lower case
---@return DyDebtEntry[]
local function filter(scan, args, email)
  local keyword = nil
  local mine = false
  for _, arg in ipairs(args) do
    if arg == 'mine' then
      mine = true
    else
      keyword = arg:upper()
    end
  end
  return vim.tbl_filter(
    function(entry)
      return (not keyword or entry.keyword == keyword)
        and (not mine or (email ~= nil and entry.mail == email))
    end,
    scan.entries
  )
end

--- List `scan`, filtered by `args`, in the quickfix list and say how much
---@param root string
---@param scan DyDebtScan
---@param args string[]
---@param email? string
local function show(root, scan, args, email)
  local now = os.time()
  local entries = M.sort(filter(scan, args, email), now)
  if #entries == 0 then
    return notify(
      #args > 0 and ('No marker matches `%s`'):format(table.concat(args, ' '))
        or ('No %s comment in the project'):format(
          table.concat(M.KEYWORDS, '/')
        )
    )
  end
  local items = {}
  for _, entry in ipairs(entries) do
    table.insert(items, {
      filename = vim.fs.joinpath(root, entry.file),
      lnum = entry.lnum,
      text = M.label(entry, now),
    })
  end
  vim.fn.setqflist({}, ' ', { title = 'Debt', items = items })
  vim.cmd('botright copen')
  local summary = M.summary(entries, now)
  if scan.reason then
    notify(
      ('%s; no ages: %s'):format(summary, scan.reason),
      vim.log.levels.WARN
    )
  else
    notify(summary)
  end
end

--- Find the markers below `root` and hand them to `done`, or why it failed
---@param root string
---@param git boolean Search what git tracks, not the whole directory
---@param done fun(entries?: DyDebtEntry[], failure?: string)
local function grep(root, git, done)
  local system = require('util.system')
  local cmd = { 'git', 'grep', '-n', '-z', '-I', '-E', M.pattern() }
  if git then
    table.insert(cmd, 3, '--untracked')
  else
    table.insert(cmd, 3, '--no-index')
    table.insert(cmd, 4, '--exclude-standard')
  end
  system.run(
    cmd,
    { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
    function(result)
      -- `git grep` exits 1 when nothing matches
      if result.code == 1 and not result.cut then return done({}) end
      if
        result.missing
        or result.timed_out
        or (result.code ~= 0 and not result.cut)
      then
        return done(nil, system.failure(result, 'git grep'))
      end
      local text = result.stdout
      if result.cut then
        notify(
          'Too many markers to read: the list stops at the size cap',
          vim.log.levels.WARN
        )
        -- What was cut ends mid-line
        text = text:gsub('[^\n]*$', '')
      end
      done(M.parse_grep(text))
    end
  )
end

--- Age `entries` in place with one `git blame` per file, a few at a time
---@param root string
---@param entries DyDebtEntry[]
---@param untracked table<string, boolean>
---@param done fun()
local function blame(root, entries, untracked, done)
  local system = require('util.system')
  local by_file, files = {}, {}
  for _, entry in ipairs(entries) do
    if untracked[entry.file] then
      entry.uncommitted = true
    else
      if not by_file[entry.file] then
        by_file[entry.file] = {}
        table.insert(files, entry.file)
      end
      table.insert(by_file[entry.file], entry)
    end
  end
  table.sort(files)
  if #files > M.MAX_FILES then
    notify(
      ('%d files have markers: only the first %d are aged'):format(
        #files,
        M.MAX_FILES
      ),
      vim.log.levels.WARN
    )
    files = vim.list_slice(files, 1, M.MAX_FILES)
  end
  local failed = {}
  system.each(files, M.JOBS, function(file, next)
    local cmd = { 'git', 'blame', '--porcelain' }
    for _, entry in ipairs(by_file[file]) do
      vim.list_extend(cmd, { '-L', ('%d,%d'):format(entry.lnum, entry.lnum) })
    end
    vim.list_extend(cmd, { '--', file })
    system.run(
      cmd,
      { cwd = root, timeout = M.TIMEOUT, max_bytes = M.MAX_BYTES },
      function(result)
        if result.code ~= 0 or result.timed_out or result.cut then
          table.insert(failed, file)
        else
          local lines = M.parse_blame(result.stdout)
          for _, entry in ipairs(by_file[file]) do
            local line = lines[entry.lnum]
            if line then
              entry.time, entry.author, entry.mail, entry.uncommitted =
                line.time, line.author, line.mail, line.uncommitted
            end
          end
        end
        next()
      end
    )
  end, function()
    if #failed > 0 then
      table.sort(failed)
      notify(
        ('git blame failed on %d files, listed without ages: %s'):format(
          #failed,
          table.concat(vim.list_slice(failed, 1, 5), ', ')
        ),
        vim.log.levels.WARN
      )
    end
    done()
  end)
end

--- The paths of `git status --porcelain -z` output that git does not track,
--- relative to the directory of `prefix` in the repository
---@param status string
---@param prefix string
---@return table<string, boolean>
function M.untracked(status, prefix)
  local found = {}
  for record in vim.gsplit(status, '\0', { trimempty = true }) do
    local path = record:match('^%?%? (.+)$')
    if path and vim.startswith(path, prefix) then
      found[path:sub(#prefix + 1)] = true
    end
  end
  return found
end

--- Hand `done` the email of the user, lower case, or nil
---@param root string
---@param done fun(email?: string)
local function user_email(root, done)
  require('util.system').run(
    { 'git', 'config', 'user.email' },
    { cwd = root, timeout = 5000 },
    function(result)
      local email = vim.trim(result.stdout or ''):lower()
      done(result.code == 0 and email ~= '' and email or nil)
    end
  )
end

--- List the TODO/FIXME/HACK/XXX comments of the project, the oldest first
---@param args? string[] A keyword to keep, and/or `mine`
function M.run(args)
  args = args or {}
  for _, arg in ipairs(args) do
    if arg ~= 'mine' and not vim.tbl_contains(M.KEYWORDS, arg:upper()) then
      return notify(
        ('Unknown argument: %s (a keyword, or mine)'):format(arg),
        vim.log.levels.ERROR
      )
    end
  end
  local root = require('util.root')()
  local system = require('util.system')
  local opts = { cwd = root, timeout = M.TIMEOUT }

  local function without_git(reason)
    if vim.tbl_contains(args, 'mine') then
      return notify(
        ('`mine` needs git blame: %s'):format(reason),
        vim.log.levels.ERROR
      )
    end
    grep(root, false, function(entries, failure)
      if not entries then return notify(failure, vim.log.levels.ERROR) end
      show(root, { entries = entries, git = false, reason = reason }, args)
    end)
  end

  local function shown(scan)
    if vim.tbl_contains(args, 'mine') then
      user_email(root, function(email)
        if not email then
          return notify(
            '`mine` needs `git config user.email`',
            vim.log.levels.ERROR
          )
        end
        show(root, scan, args, email)
      end)
    else
      show(root, scan, args)
    end
  end

  system.run(
    { 'git', 'rev-parse', 'HEAD', '--show-prefix' },
    opts,
    function(rev)
      if rev.missing then return notify(rev.stderr, vim.log.levels.ERROR) end
      local head, prefix = (rev.stdout or ''):match('^(%x+)\n([^\n]*)')
      if rev.code ~= 0 or not head then
        local why =
          vim.split(vim.trim(system.failure(rev, 'git rev-parse')), '\n')
        return without_git(
          ('not a git repository with commits (%s)'):format(why[#why])
        )
      end
      system.run(
        {
          'git',
          '--no-optional-locks',
          'status',
          '--porcelain',
          '-z',
          '--untracked-files=all',
        },
        opts,
        function(status)
          if status.code ~= 0 or status.timed_out or status.cut then
            return notify(
              system.failure(status, 'git status'),
              vim.log.levels.ERROR
            )
          end
          -- shortcut: a dirty file edited again keeps the key, so its new lines
          -- show up after the next commit or `:DyDebt` in a new session
          local key = head .. '\0' .. status.stdout
          local cached = M.cache[root]
          if cached and cached.key == key then return shown(cached.scan) end
          grep(root, true, function(entries, failure)
            if not entries then return notify(failure, vim.log.levels.ERROR) end
            blame(root, entries, M.untracked(status.stdout, prefix), function()
              local scan = { entries = entries, git = true }
              M.cache[root] = { key = key, scan = scan }
              shown(scan)
            end)
          end)
        end
      )
    end
  )
end

return M
