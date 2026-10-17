--- What a plugin update would bring in, read before it lands
---
--- `tools.lazy-quarantine` holds a fresh commit back for a week so that a
--- compromised release has time to be caught -- by someone. This is the
--- part of the catching that can be done here: the commits waiting for each
--- plugin, and the lines they add that do what a plugin rarely needs to and
--- an attacker always does -- start a process, load code at runtime, reach
--- the network, read a credential, delete files, hide a blob.
---
--- A flag is a reason to read the diff, not a verdict: a plugin that talks to
--- an LSP or opens a URL does most of these for a living. What matters is a
--- flag nobody expected in a plugin that never did it before.
local M = {}

local notify = require('util.notify').titled('Quarantine')

--- What a line added by an update is flagged for, by Lua pattern
---@type { name: string, patterns: string[] }[]
M.rules = {
  {
    name = 'runs a process',
    patterns = {
      'vim%.system%s*%(',
      'vim%.fn%.system',
      'jobstart%s*%(',
      'termopen%s*%(',
      'io%.popen',
      'os%.execute',
      '%.spawn%s*%(',
    },
  },
  {
    name = 'loads code at runtime',
    patterns = {
      'loadstring%s*%(',
      '%f[%w_.:]load%s*%(',
      'loadfile%s*%(',
      'dofile%s*%(',
      'require%s*%(?%s*[\'"]ffi[\'"]',
    },
  },
  {
    name = 'reaches the network',
    patterns = {
      'https?://',
      '%f[%w]curl%f[%W]',
      '%f[%w]wget%f[%W]',
      'new_tcp',
      'new_udp',
      'getaddrinfo',
    },
  },
  {
    name = 'touches credentials',
    patterns = {
      '%.ssh/',
      '%.gnupg',
      '%.aws/',
      '%.netrc',
      '%.git%-credentials',
      '_TOKEN%f[%W]',
      'id_rsa',
      'id_ed25519',
    },
  },
  {
    name = 'deletes or moves files',
    patterns = {
      'os%.remove',
      'os%.rename',
      'fs_unlink',
      'fs_rmdir',
      'fs_rename',
      'vim%.fn%.delete%s*%(',
      'rm %-[rf][rf]?',
    },
  },
  {
    name = 'carries an encoded blob',
    patterns = { string.rep('[%w+/=]', 160) },
  },
}

--- Files whose change alters what runs on install or build, whatever is in
--- them: lazy.nvim runs `build.lua` and a `build` command as the plugin
--- lands, before any of its Lua is required
local BUILD_FILES = {
  ['build.lua'] = true,
  ['Makefile'] = true,
  ['makefile'] = true,
  ['CMakeLists.txt'] = true,
  ['Cargo.toml'] = true,
  ['go.mod'] = true,
  ['package.json'] = true,
  ['justfile'] = true,
  ['build.sh'] = true,
  ['install.sh'] = true,
  ['pyproject.toml'] = true,
  ['setup.py'] = true,
  ['flake.nix'] = true,
  -- Lockfiles: a dependency swapped under a build that stays the same
  ['Cargo.lock'] = true,
  ['go.sum'] = true,
  ['package-lock.json'] = true,
  ['yarn.lock'] = true,
  ['pnpm-lock.yaml'] = true,
}

--- Directories of a plugin that never run in the editor: its CI, which runs
--- on the forge, and its tests, which lazy.nvim does not run either
local NOT_RUN = {
  '^%.github/',
  '^%.gitlab/',
  '^%.gitlab%-ci%.ya?ml$',
  '^%.forgejo/',
  '^%.gitea/',
  '^%.circleci/',
  '^tests?/',
  '^spec/',
}

--- Whether `path` is something the rules would only cry wolf over: prose --
--- docs, licences, changelogs, where a URL is a link and `rm -rf` an example
--- -- or a file that never runs here. A `.txt` outside `doc/` is read:
--- `requirements.txt` is what a build installs.
---@param path string
---@return boolean
local function is_ignored(path)
  for _, pattern in ipairs(NOT_RUN) do
    if path:find(pattern) then return true end
  end
  local name = vim.fs.basename(path)
  return path:find('^doc/') ~= nil
    or name:find('%.md$') ~= nil
    or name:find('%.rst$') ~= nil
    or name:find('^LICEN[CS]E') ~= nil
    or name:find('^CHANGELOG') ~= nil
end

--- Whether `text` is a comment and nothing else, which no rule is about
---
--- Vimscript's `"` is left out: in Lua it opens a string, and a table of
--- strings is exactly where a command line hides.
---@param text string
---@return boolean
local function is_comment(text)
  -- A block comment closed on the line hides nothing: what follows it runs
  local after = text:match('^%s*%-%-%[(=*)%[')
  if after then
    local close = text:find(']' .. after .. ']', 1, true)
    return not close or vim.trim(text:sub(close + #after + 2)) == ''
  end
  return text:find('^%s*%-%-') ~= nil
    or text:find('^%s*#') ~= nil
    or text:find('^%s*//') ~= nil
end

---@class DyReviewFinding
---@field file string
---@field line? integer
---@field rule string
---@field text? string

--- The path of an unquoted `diff --git a/P b/P` header that names one file
---
--- git does not quote a space, so `a/plugin/x b/tests/y.lua` cannot be split
--- at the first ` b/`: the header is read as the same path twice instead.
--- nil for a rename, whose two paths differ.
---@param raw string
---@return string?
local function same_path(raw)
  local rest = raw:match('^diff %-%-git (a/.*)$')
  if not rest or rest:sub(1, 1) == '"' then return nil end
  -- `a/P b/P`: 2 + #P + 3 + #P characters
  local len = (#rest - 5) / 2
  if len < 1 or len % 1 ~= 0 then return nil end
  local a, b = rest:sub(3, 2 + len), rest:sub(-len)
  if a == b and rest:sub(3 + len, 5 + len) == ' b/' then return b end
end

--- Flag the lines a diff adds
---
--- `diff` is the output of `git diff --unified=0`, as lines.
---@param diff string[]
---@return DyReviewFinding[]
function M.scan(diff)
  ---@type DyReviewFinding[]
  local findings = {}
  local file, line, in_hunk, skip = nil, 0, false, false

  for _, raw in ipairs(diff) do
    local b_path = same_path(raw)
      or raw:match('^diff %-%-git a/.- b/(.*)$')
      -- git quotes a path it would not print as it is (`core.quotePath`)
      or raw:match('^diff %-%-git "a/.-" "b/(.*)"$')
    if not b_path and raw:find('^diff %-%-git ') then
      -- Never a hunk read as the file before it, whatever the header says
      b_path = raw:match(' "?b/(.-)"?$') or '?'
    end
    if b_path then
      file, in_hunk, skip = b_path, false, is_ignored(b_path)
      if BUILD_FILES[vim.fs.basename(file)] or file:find('%.rockspec$') then
        table.insert(findings, { file = file, rule = 'changes the build' })
      end
    elseif raw:find('^Binary files ') then
      local binary = raw:match(' and b/(.*) differ$')
      if binary then
        table.insert(findings, { file = binary, rule = 'adds a binary file' })
      end
    elseif raw:find('^@@ ') then
      in_hunk = true
      line = tonumber(raw:match('^@@ %-%d+,?%d* %+(%d+)')) or 0
    elseif in_hunk and file and raw:sub(1, 1) == '+' then
      local text = raw:sub(2)
      if not skip and not is_comment(text) then
        for _, rule in ipairs(M.rules) do
          for _, pattern in ipairs(rule.patterns) do
            if text:find(pattern) then
              table.insert(findings, {
                file = file,
                line = line,
                rule = rule.name,
                text = vim.trim(text),
              })
              break
            end
          end
        end
      end
      line = line + 1
    end
  end
  return findings
end

--- Longest a `git` run may take, in milliseconds
M.TIMEOUT = 60000

--- Most bytes of `git` output read: a plugin vendoring a big file, or a
--- year of commits, would otherwise fill a buffer with hundreds of MB
M.MAX_OUTPUT = 4 * 1024 * 1024

--- `M.MAX_OUTPUT` as it is shown
---@return string
local function max_output()
  local mib = M.MAX_OUTPUT / 1024 / 1024
  return mib >= 1 and ('%g MiB'):format(mib)
    or ('%d bytes'):format(M.MAX_OUTPUT)
end

--- Plugins read at once
M.JOBS = 4

--- Run `git` in `dir` in the background, and hand its output as lines to
--- `callback`, or nil on failure; `cut` is true when it was cut at
--- `M.MAX_OUTPUT`
---
--- In the background, as lazy's partial clones fetch the blobs of a commit
--- only when `git diff` asks for them, over the network, and waiting on that
--- would freeze the editor.
---@param dir string
---@param args string[]
---@param callback fun(lines: string[]?, cut: boolean?)
local function git(dir, args, callback)
  -- Paths as they are, never quoted, for `scan` to read
  local command = { 'git', '-c', 'core.quotePath=false', '-C', dir }
  vim.list_extend(command, args)
  require('util.system').run(
    command,
    { timeout = M.TIMEOUT, max_bytes = M.MAX_OUTPUT },
    function(result)
      -- Stopped for its size is not a failure
      if not result.cut and result.code ~= 0 then return callback(nil) end
      callback(vim.split(result.stdout, '\n', { trimempty = true }), result.cut)
    end
  )
end

--- The commits `row` would bring in, newest first, as `short date subject`;
--- nil when git could not list them, and whether the list was cut
---@param row DyPendingUpdate
---@param callback fun(commits: string[]?, cut?: boolean)
function M.commits(row, callback)
  git(row.dir, {
    'log',
    '--no-color',
    '--format=%h %cs %s',
    row.from .. '..' .. row.to,
  }, function(lines, cut)
    -- The last line of a cut list is cut too
    if cut and lines then table.remove(lines) end
    callback(lines, cut)
  end)
end

--- What the commits of `row` add, flagged
---@param row DyPendingUpdate
---@param callback fun(findings: DyReviewFinding[])
function M.findings(row, callback)
  git(row.dir, {
    'diff',
    '--no-color',
    -- Neither a diff driver nor a textconv filter of the user's config
    -- stands between the scan and the bytes that land
    '--no-ext-diff',
    '--no-textconv',
    '--no-renames',
    -- `scan` reads the paths off `a/` and `b/`, which `diff.noprefix` and
    -- `diff.mnemonicPrefix` in a user's config would take away
    '--src-prefix=a/',
    '--dst-prefix=b/',
    '--unified=0',
    row.from,
    row.to,
  }, function(diff, cut)
    -- A diff that could not be read -- lazy's partial clones fetch the blobs
    -- of a commit only now, and the network may be down -- is no clean diff
    if not diff then
      return callback({
        { file = row.dir, rule = 'diff unavailable, nothing was read' },
      })
    end
    local findings = M.scan(diff)
    -- Nor is one read in part
    if cut then
      table.insert(findings, {
        file = row.dir,
        rule = ('diff cut at %s, the rest was not read'):format(max_output()),
      })
    end
    callback(findings)
  end)
end

--- Longest a line of code is quoted in the report
local QUOTE_WIDTH = 72

--- Line numbers listed for a flag raised more than once in a file
local MAX_LINES = 5

---@class DyReviewGroup
---@field file string
---@field rule string
---@field findings DyReviewFinding[]

--- The findings of the same rule in the same file, together, in the order
--- each first turned up
---
--- A schema catalog adds a hundred URLs in one update, each of them a flag;
--- one line saying so reads better than a hundred.
---@param findings DyReviewFinding[]
---@return DyReviewGroup[]
function M.group(findings)
  local groups, by_key = {}, {}
  for _, finding in ipairs(findings) do
    local key = finding.file .. '\0' .. finding.rule
    if not by_key[key] then
      by_key[key] = { file = finding.file, rule = finding.rule, findings = {} }
      table.insert(groups, by_key[key])
    end
    table.insert(by_key[key].findings, finding)
  end
  return groups
end

--- One line of the report for `group`
---@param group DyReviewGroup
---@return string
function M.describe(group)
  local first = group.findings[1]
  local line
  if #group.findings == 1 then
    line = ('- %s  %s'):format(
      first.line and ('%s:%d'):format(group.file, first.line) or group.file,
      group.rule
    )
  else
    local numbers = {}
    for index, finding in ipairs(group.findings) do
      if index > MAX_LINES then
        table.insert(numbers, '…')
        break
      end
      table.insert(numbers, tostring(finding.line))
    end
    line = ('- %s  %s ×%d (lines %s)'):format(
      group.file,
      group.rule,
      #group.findings,
      table.concat(numbers, ', ')
    )
  end
  if first.text then
    local text = first.text
    if vim.fn.strchars(text) > QUOTE_WIDTH then
      text = vim.fn.strcharpart(text, 0, QUOTE_WIDTH) --[[@as string]] .. '…'
    end
    line = line .. ('  `%s`'):format((text:gsub('`', "'")))
  end
  return line
end

--- The section of the report on `row`
---@param row DyPendingUpdate
---@param callback fun(lines: string[])
local function section(row, callback)
  M.commits(row, function(commits, cut)
    M.findings(row, function(findings)
      local state = row.held
          and ('held %d more days'):format(math.ceil(row.clears / 86400))
        or 'out of quarantine'
      -- A failed `git log` must not read as an update with nothing in it
      local count = commits
          and (
            cut and '%d+ commits, the list cut at ' .. max_output()
            or '%d commits'
          ):format(#commits)
        or 'commits unavailable, nothing was read'
      local lines = {
        '',
        ('## %s  %s..%s  %s, %s'):format(
          row.name,
          row.from:sub(1, 7),
          row.to:sub(1, 7),
          count,
          state
        ),
        '',
      }
      commits = commits or {}
      for index, commit in ipairs(commits) do
        if index > 15 then
          table.insert(lines, ('- … and %d more'):format(#commits - 15))
          break
        end
        table.insert(lines, '- ' .. commit)
      end

      table.insert(lines, '')
      if #findings == 0 then
        table.insert(lines, 'No flags.')
      else
        table.insert(lines, ('Flags (%d):'):format(#findings))
        for _, group in ipairs(M.group(findings)) do
          table.insert(lines, M.describe(group))
        end
      end
      callback(lines)
    end)
  end)
end

--- The header of the report on `rows`
---@param rows DyPendingUpdate[]
---@param window integer The quarantine window, in seconds
---@return string[]
local function header(rows, window)
  return {
    ('# Plugin updates waiting: %d'):format(#rows),
    '',
    (
      'Quarantine window: %d days. `<CR>` on a plugin opens its diff, `q` '
      .. 'closes.'
    ):format(math.floor(window / 86400)),
  }
end

--- The report on `rows`, as Markdown lines handed to `callback`
---
--- `M.JOBS` plugins are read at once, and their sections kept in the order
--- of `rows` whichever finishes first.
---@param rows DyPendingUpdate[]
---@param window integer The quarantine window, in seconds
---@param callback fun(lines: string[])
function M.report(rows, window, callback)
  local lines = header(rows, window)
  if #rows == 0 then
    vim.list_extend(
      lines,
      { '', 'Every plugin is on the commit it would update to.' }
    )
    return callback(lines)
  end

  local sections = {} ---@type string[][]
  local started, running, finished = 0, 0, 0
  local function start()
    while running < M.JOBS and started < #rows do
      started = started + 1
      running = running + 1
      local index = started
      section(rows[index], function(section_lines)
        sections[index] = section_lines
        running = running - 1
        finished = finished + 1
        if finished < #rows then return start() end
        for _, part in ipairs(sections) do
          vim.list_extend(lines, part)
        end
        callback(lines)
      end)
    end
  end
  start()
end

--- Put `lines` in the read-only buffer `bufnr`, if it is still there
---@param bufnr integer
---@param lines string[]
function M.fill(bufnr, lines) require('util.scratch').set(bufnr, lines) end

--- A scratch buffer holding `lines`, in a tab of its own
---@param lines string[]
---@param filetype string
---@return integer bufnr
local function scratch(lines, filetype)
  return require('util.scratch').open(lines, { filetype = filetype })
end

--- The whole of what `row` brings in, commit by commit, in a tab
---@param row DyPendingUpdate
function M.open_diff(row)
  local bufnr =
    scratch({ ('Reading the commits of %s…'):format(row.name) }, 'git')
  git(row.dir, {
    'log',
    '--no-color',
    '--no-ext-diff',
    '--no-textconv',
    '--stat',
    '--patch',
    row.from .. '..' .. row.to,
  }, function(log, cut)
    log = log or { 'git log failed in ' .. row.dir }
    if cut then table.insert(log, ('[cut at %s]'):format(max_output())) end
    M.fill(bufnr, log)
  end)
end

--- The plugin whose section the cursor is in
---@param bufnr integer
---@return string?
local function section_at_cursor(bufnr)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  for index = row, 1, -1 do
    local line = vim.api.nvim_buf_get_lines(bufnr, index - 1, index, false)[1]
    local name = line and line:match('^## (%S+)')
    if name then return name end
  end
end

--- `:DyQuarantine review [{plugin}]`
---
--- Without a plugin, the report on every update waiting; with one, its full
--- diff. A `git log` and a `git diff` per plugin, which is why it is a
--- command and not something shown as updates are checked for. The tab
--- opens at once, and fills in as git answers.
---@param rows DyPendingUpdate[]
---@param window integer
---@param name? string
function M.show(rows, window, name)
  ---@type table<string, DyPendingUpdate>
  local by_name = {}
  for _, row in ipairs(rows) do
    by_name[row.name] = row
  end

  if name and name ~= '' then
    if not by_name[name] then
      return notify(name .. ' has no update waiting', vim.log.levels.WARN)
    end
    return M.open_diff(by_name[name])
  end

  local waiting = header(rows, window)
  vim.list_extend(
    waiting,
    { '', ('Reading the updates of %d plugins…'):format(#rows) }
  )
  local bufnr = scratch(waiting, 'markdown')
  M.report(rows, window, function(lines) M.fill(bufnr, lines) end)
  vim.keymap.set('n', '<CR>', function()
    local plugin = section_at_cursor(bufnr)
    if plugin and by_name[plugin] then M.open_diff(by_name[plugin]) end
  end, { buffer = bufnr, desc = 'Open the diff of this plugin' })
end

return M
