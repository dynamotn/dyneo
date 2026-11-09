--- Pending snapshot-test changes, reviewed and accepted or rejected
---
--- Like `cargo insta review`, inside the editor. Three sources, each found by
--- what the project holds:
---
--- - insta (Rust) writes a pending change as `x.snap.new` next to `x.snap`:
---   accepting moves it over `x.snap` (its header comes with it), rejecting
---   deletes it.
--- - jest and vitest keep no pending file: the suite runs once with `--json`
---   and every failing snapshot assertion is listed; accepting runs the test
---   file again with `-u`, which rewrites every snapshot of that file.
--- - syrupy (Python, `__snapshots__/*.ambr`) is the same through pytest's
---   JUnit report and `--snapshot-update`.
---
--- Running a suite runs code of the project, so it asks `util.trust` first.
local M = {}

local system = require('util.system')

--- The deadline of one test-suite run, in milliseconds
M.TIMEOUT = 5 * 60 * 1000

--- The size of a snapshot file read whole
M.MAX_FILE = 1024 * 1024

--- Directories never searched for snapshots
M.SKIP = { '.git', 'node_modules', 'target', '.venv', 'venv' }

local function notify(msg, level)
  vim.notify(
    msg,
    level or vim.log.levels.INFO,
    { title = require('util.notify').title('Snapshots') }
  )
end

---@alias DySnapshotKind 'insta'|'jest'|'vitest'|'syrupy'

---@class DySnapshot
---@field kind DySnapshotKind
---@field root string
---@field file string insta: the `.snap.new`; else the test file
---@field target? string insta: the `.snap` it replaces
---@field name string The test or snapshot
---@field old? string[] From the runner's report
---@field new? string[]

-- Reading snapshots -----------------------------------------------------------

--- The lines of `path`, nil when it is missing or too big to read
---@param path string
---@return string[]?
local function read(path)
  local stat = vim.uv.fs_stat(path)
  if not stat or stat.size > M.MAX_FILE then return nil end
  return vim.fn.readfile(path)
end

--- An insta snapshot split into its `---` header and its body
---@param lines string[]
---@return string[] header
---@return string[] body
function M.split(lines)
  if lines[1] == '---' then
    for i = 2, #lines do
      if lines[i] == '---' then
        return vim.list_slice(lines, 1, i), vim.list_slice(lines, i + 1)
      end
    end
  end
  return {}, lines
end

--- The two sides of a diff whose lines start with `- `, `+ ` or `  `; nil
--- when no line is either side's own
---@param lines string[]
---@return string[]? old
---@return string[]? new
function M.diff_sides(lines)
  local old, new, changed = {}, {}, false
  for _, line in ipairs(lines) do
    local mark, text = line:sub(1, 1), line:sub(3)
    if mark == '-' then
      table.insert(old, text)
      changed = true
    elseif mark == '+' then
      table.insert(new, text)
      changed = true
    else
      table.insert(old, text)
      table.insert(new, text)
    end
  end
  if changed then return old, new end
end

--- The sides of a jest failure message: the lines after its `+ Received`
--- header, up to the stack
---@param message string
---@return string[]? old
---@return string[]? new
function M.jest_sides(message)
  local lines = vim.split(message:gsub('\27%[[%d;]*m', ''), '\n')
  for i, line in ipairs(lines) do
    if line:match('^%+ Received') then
      local body = {}
      for j = i + 1, #lines do
        if lines[j]:match('^%s+at ') then break end
        table.insert(body, lines[j])
      end
      while body[1] == '' do
        table.remove(body, 1)
      end
      return M.diff_sides(body)
    end
  end
end

--- The entry `name` of a jest or vitest `.snap` file
---@param path string
---@param name string
---@return string[]?
function M.stored(path, name)
  local lines = read(path)
  if not lines then return nil end
  local head = 'exports[`' .. name .. '`] = `'
  for i, line in ipairs(lines) do
    if vim.startswith(line, head) then
      local entry = { line:sub(#head + 1) }
      for j = i + 1, #lines do
        if lines[j] == '`;' then break end
        table.insert(entry, lines[j])
      end
      if entry[1] == '' then table.remove(entry, 1) end
      return entry
    end
  end
end

--- What `item` held and what it holds now, as lines
---@param item DySnapshot
---@return string[] old
---@return string[] new
function M.sides(item)
  if item.kind == 'insta' then
    local _, old = M.split(item.target and read(item.target) or {})
    local _, new = M.split(read(item.file) or { '(too big to show)' })
    return old, new
  end
  return item.old or {}, item.new or {}
end

-- Finding them ----------------------------------------------------------------

--- `path` relative to `root`
local function relative(root, path)
  if vim.startswith(path, root .. '/') then return path:sub(#root + 2) end
  return path
end

--- The insta items of `paths` (every `.snap.new` found)
---@param root string
---@param paths string[]
---@return DySnapshot[]
function M.insta_items(root, paths)
  local items = {}
  for _, path in ipairs(paths) do
    if path:match('%.snap%.new$') then
      local target = path:sub(1, -5)
      table.insert(items, {
        kind = 'insta',
        root = root,
        file = path,
        target = vim.uv.fs_stat(target) and target or nil,
        name = vim.fs.basename(target):gsub('%.snap$', ''):gsub('__', '::'),
      })
    end
  end
  table.sort(items, function(a, b) return a.file < b.file end)
  return items
end

--- The failing snapshots of a jest or vitest `--json` report
---@param root string
---@param kind 'jest'|'vitest'
---@param json string
---@return DySnapshot[]?
---@return string? err Why the report was not read, or what it left out
function M.js_items(root, kind, json)
  -- Anything printed before the report is the project's own
  local ok, report = pcall(vim.json.decode, json:match('{.*') or '')
  if not ok or type(report) ~= 'table' or not report.testResults then
    return nil, kind .. ' gave no JSON report'
  end
  local items = {}
  for _, result in ipairs(report.testResults) do
    for _, assertion in ipairs(result.assertionResults or {}) do
      for _, message in ipairs(assertion.failureMessages or {}) do
        local name = message:match('Snapshot name: `(.-)`')
          or message:match('Snapshot `(.-)` mismatched')
        if name then
          local old, new = M.jest_sides(message)
          if not old then
            -- vitest's report carries no diff: the stored side only
            local snap = vim.fs.joinpath(
              vim.fs.dirname(result.name),
              '__snapshots__',
              vim.fs.basename(result.name) .. '.snap'
            )
            old = M.stored(snap, name) or {}
            new =
              { '(not in the report: accepting writes what the test gives)' }
          end
          table.insert(items, {
            kind = kind,
            root = root,
            file = result.name,
            name = name,
            old = old,
            new = new,
          })
        end
      end
    end
  end
  -- A failure whose message names no snapshot is still one: say so
  local unmatched = type(report.snapshot) == 'table'
      and tonumber(report.snapshot.unmatched)
    or 0
  if unmatched > #items then
    return items,
      ('%d of %d failing snapshots have no name in the report'):format(
        unmatched - #items,
        unmatched
      )
  end
  return items
end

local ENTITIES = { lt = '<', gt = '>', amp = '&', quot = '"', apos = "'" }

--- `text` with its XML entities decoded
local function unescape(text)
  return (
    text:gsub('&(#?)(%w+);', function(hash, code)
      if hash == '#' then return vim.fn.nr2char(tonumber(code) or 63) end
      return ENTITIES[code]
    end)
  )
end

--- The failing syrupy snapshots of a pytest JUnit report (`xunit1`)
---@param root string
---@param xml string
---@return DySnapshot[]
function M.syrupy_items(root, xml)
  local items = {}
  xml = xml:gsub('<testcase%s[^>]-/>', '')
  for attrs, body in xml:gmatch('<testcase%s([^>]*)>(.-)</testcase>') do
    local message = body:match('<failure%s+message="(.-)"')
    message = message and unescape(message)
    if message and message:find('== [- snapshot]', 1, true) then
      local file = unescape((' ' .. attrs):match('%sfile="(.-)"') or '')
      local name = unescape((' ' .. attrs):match('%sname="(.-)"') or '?')
      local class = (attrs:match('classname="(.-)"') or ''):match('[^.]+$')
      if class and class ~= vim.fn.fnamemodify(file, ':t:r') then
        name = class .. '::' .. name
      end
      local lines = vim.split(message, '\n')
      table.remove(lines, 1)
      local diff = vim.tbl_map(function(l) return l:sub(3) end, lines)
      local old, new = M.diff_sides(diff)
      table.insert(items, {
        kind = 'syrupy',
        root = root,
        file = vim.startswith(file, '/') and file
          or vim.fs.joinpath(root, file),
        name = name,
        old = old or {},
        new = new or {},
      })
    end
  end
  return items
end

--- The suite runner of `root` this module knows, if any
---@param root string
---@param paths string[] The snapshot files found
---@return { kind: DySnapshotKind, bin: string }?
function M.runner(root, paths)
  local function bin(rel)
    local full = vim.fs.joinpath(root, rel)
    if vim.fn.executable(full) == 1 then return full end
  end
  if vim.uv.fs_stat(vim.fs.joinpath(root, 'package.json')) then
    local jest = bin('node_modules/.bin/jest')
    if jest then return { kind = 'jest', bin = jest } end
    local vitest = bin('node_modules/.bin/vitest')
    if vitest then return { kind = 'vitest', bin = vitest } end
  end
  for _, path in ipairs(paths) do
    if path:match('/__snapshots__/.*%.ambr$') then
      local pytest = bin('.venv/bin/pytest')
        or bin('venv/bin/pytest')
        or (vim.fn.executable('pytest') == 1 and 'pytest')
      if pytest then return { kind = 'syrupy', bin = pytest } end
      return nil
    end
  end
end

--- The command finding the failing snapshots; `report` is the JUnit file
---@param runner { kind: DySnapshotKind, bin: string }
---@param report string
---@return string[]
function M.scan_command(runner, report)
  if runner.kind == 'jest' then return { runner.bin, '--ci', '--json' } end
  if runner.kind == 'vitest' then
    return { runner.bin, 'run', '--reporter=json' }
  end
  return {
    runner.bin,
    '-q',
    '-p',
    'no:cacheprovider',
    '-o',
    'junit_family=xunit1',
    '--junitxml',
    report,
  }
end

--- The command accepting every snapshot of test file `file`
---@param runner { kind: DySnapshotKind, bin: string }
---@param file string
---@return string[]
function M.accept_command(runner, file)
  if runner.kind == 'jest' then
    return { runner.bin, '--ci=false', '-u', '--runTestsByPath', file }
  end
  if runner.kind == 'vitest' then return { runner.bin, 'run', '-u', file } end
  return {
    runner.bin,
    '-q',
    '-p',
    'no:cacheprovider',
    '--snapshot-update',
    file,
  }
end

--- Find the pending snapshots under `root`; `on_done` gets them, or nil
--- when nothing could be searched
---@param root string
---@param on_done fun(items: DySnapshot[]?, runner?: { kind: DySnapshotKind, bin: string })
function M.scan(root, on_done)
  local cmd = { 'find', root }
  for i, dir in ipairs(M.SKIP) do
    vim.list_extend(cmd, { i == 1 and '(' or '-o', '-name', dir })
  end
  vim.list_extend(cmd, {
    ')',
    '-prune',
    '-o',
    '(',
    '-name',
    '*.snap.new',
    '-o',
    '-name',
    '*.pending-snap',
    '-o',
    '-name',
    '*.ambr',
    ')',
    '-print',
  })
  system.run(cmd, { timeout = 30 * 1000 }, function(found)
    if found.code ~= 0 then
      notify(
        'Snapshots not searched: ' .. system.failure(found, 'find'),
        vim.log.levels.ERROR
      )
      return on_done(nil)
    end
    local paths = vim.split(vim.trim(found.stdout), '\n', { trimempty = true })
    local items = M.insta_items(root, paths)
    local inline = #vim.tbl_filter(
      function(p) return p:match('%.pending%-snap$') ~= nil end,
      paths
    )
    if inline > 0 then
      notify(
        ('%d files of inline insta snapshots pending, not shown here: `cargo insta review` takes them'):format(
          inline
        ),
        vim.log.levels.WARN
      )
    end
    local runner = M.runner(root, paths)
    if not runner then return on_done(items) end
    local question = ('Run the %s suite to find failing snapshots?\nThe tests run code of the project in %s, as you.'):format(
      runner.kind,
      vim.fn.fnamemodify(root, ':~')
    )
    if not require('util.trust').ask('snapshots', root, question) then
      notify(
        ('%s snapshots not searched: the project is not trusted'):format(
          runner.kind
        ),
        vim.log.levels.WARN
      )
      return on_done(items, nil)
    end
    notify(('Running %s to find failing snapshots'):format(runner.kind))
    local report = vim.fn.tempname() .. '.xml'
    system.run(M.scan_command(runner, report), {
      cwd = root,
      timeout = M.TIMEOUT,
      detach = true,
      -- Without CI, vitest writes snapshots it has not seen
      env = { CI = 'true' },
    }, function(result)
      local more, err
      if result.missing or result.timed_out or result.cut then
        err = system.failure(result, runner.kind)
      elseif runner.kind == 'syrupy' then
        local xml = read(report)
        os.remove(report)
        if xml then
          more = M.syrupy_items(root, table.concat(xml, '\n'))
        else
          err = 'pytest wrote no report: ' .. system.failure(result, 'pytest')
        end
      else
        more, err =
          M.js_items(root, runner.kind --[[@as 'jest'|'vitest']], result.stdout)
      end
      if err then
        notify(
          ('%s snapshots: %s'):format(runner.kind, err),
          vim.log.levels.ERROR
        )
      end
      on_done(vim.list_extend(items, more or {}), runner)
    end)
  end)
end

-- Acting on them --------------------------------------------------------------

---@class DySnapshotSession
---@field items DySnapshot[]
---@field index integer
---@field runner? { kind: DySnapshotKind, bin: string }
---@field tab? integer

--- The review going on, nil when none
---@type DySnapshotSession?
M.session = nil

--- Accept `item`; `on_done` gets whether it was, and the items it settled
---@param item DySnapshot
---@param runner? { kind: DySnapshotKind, bin: string }
---@param on_done fun(ok: boolean)
function M.accept(item, runner, on_done)
  if item.kind == 'insta' then
    local ok, err = vim.uv.fs_rename(item.file, item.file:sub(1, -5))
    if not ok then
      notify('Not accepted: ' .. tostring(err), vim.log.levels.ERROR)
    end
    return on_done(ok == true)
  end
  if not runner then
    notify('Not accepted: no test runner', vim.log.levels.ERROR)
    return on_done(false)
  end
  local cmd = M.accept_command(runner, item.file)
  local answer = vim.fn.confirm(
    ('Run `%s`?\nIt rewrites every snapshot of %s.'):format(
      table.concat(cmd, ' '),
      relative(item.root, item.file)
    ),
    '&Run\n&Cancel',
    2
  )
  if answer ~= 1 then return on_done(false) end
  system.run(
    cmd,
    { cwd = item.root, timeout = M.TIMEOUT, detach = true },
    function(result)
      if result.code ~= 0 then
        notify(
          'Not accepted: ' .. system.failure(result, runner.kind),
          vim.log.levels.ERROR
        )
      end
      on_done(result.code == 0)
    end
  )
end

--- Reject insta `item` by deleting its `.snap.new`, once confirmed
---@param item DySnapshot
---@return boolean
function M.reject(item)
  if item.kind ~= 'insta' then
    notify(
      ('%s keeps no pending file: the snapshot stays, and the test keeps failing'):format(
        item.kind
      ),
      vim.log.levels.WARN
    )
    return false
  end
  local answer = vim.fn.confirm(
    ('Delete %s?'):format(relative(item.root, item.file)),
    '&Delete\n&Cancel',
    2
  )
  if answer ~= 1 then return false end
  local ok, err = os.remove(item.file)
  if not ok then
    notify('Not rejected: ' .. tostring(err), vim.log.levels.ERROR)
  end
  return ok == true
end

--- Drop the items settled with `item`: itself, or every one of its test
--- file for a runner
---@param session DySnapshotSession
---@param item DySnapshot
local function settle(session, item)
  session.items = vim.tbl_filter(
    function(other)
      return other ~= item and (item.kind == 'insta' or other.file ~= item.file)
    end,
    session.items
  )
  if session.index > #session.items then session.index = 1 end
end

--- Close the review tab, if open
---@param session DySnapshotSession
local function close(session)
  local tab = session.tab
  session.tab = nil
  if tab and vim.api.nvim_tabpage_is_valid(tab) then
    if #vim.api.nvim_list_tabpages() > 1 then
      vim.cmd.tabclose(vim.api.nvim_tabpage_get_number(tab))
    else
      vim.cmd('silent! only | enew')
    end
  end
end

--- Stop the review
function M.quit()
  if M.session then close(M.session) end
  M.session = nil
end

--- Show the item of the session at its index, or say the review is over
---@param skipped? boolean
function M.show(skipped)
  local session = M.session
  if not session then return end
  close(session)
  local item = session.items[session.index]
  if not item or (skipped and session.index == 1) then
    M.session = nil
    return notify(
      #session.items == 0 and 'No more pending snapshots'
        or ('%d pending snapshots left'):format(#session.items)
    )
  end
  local old, new = M.sides(item)
  local scratch = require('util.scratch')
  local label = relative(item.root, item.file) .. ' ' .. item.name
  local left = scratch.open(old, { name = 'dysnapshots://old/' .. label })
  session.tab = vim.api.nvim_get_current_tabpage()
  vim.cmd.diffthis()
  local right = scratch.open(
    new,
    { name = 'dysnapshots://new/' .. label, split = 'vertical' }
  )
  vim.cmd.diffthis()
  local keys = {
    a = {
      function()
        M.accept(item, session.runner, function(ok)
          if ok then settle(session, item) end
          M.show()
        end)
      end,
      'Accept the snapshot',
    },
    x = {
      function()
        if M.reject(item) then
          settle(session, item)
          M.show()
        end
      end,
      'Reject the snapshot',
    },
    n = {
      function()
        session.index = session.index % #session.items + 1
        M.show(true)
      end,
      'Skip to the next snapshot',
    },
    q = { M.quit, 'Quit the snapshot review' },
  }
  for _, bufnr in ipairs({ left, right }) do
    for lhs, spec in pairs(keys) do
      vim.keymap.set(
        'n',
        lhs,
        spec[1],
        { buffer = bufnr, desc = spec[2], nowait = true }
      )
    end
  end
  notify(
    ('%s: a accept, x reject, n next, q quit (%d of %d)'):format(
      label,
      session.index,
      #session.items
    )
  )
end

--- The picker items of `items`
---@param items DySnapshot[]
---@return table[]
function M.picker_items(items)
  local diff = vim.text and vim.text.diff or vim.diff
  local out = {}
  for i, item in ipairs(items) do
    local old, new = M.sides(item)
    local rel = relative(item.root, item.file)
    out[i] = {
      text = table.concat({ item.kind, rel, item.name }, ' '),
      index = i,
      snapshot = item,
      preview = {
        text = diff(
          table.concat(old, '\n') .. '\n',
          table.concat(new, '\n') .. '\n'
        ) --[[@as string]],
        ft = 'diff',
      },
      rel = rel,
    }
  end
  return out
end

--- Act on every item at once, once confirmed with their count
---@param items DySnapshot[]
---@param runner? { kind: DySnapshotKind, bin: string }
---@param action 'accept-all'|'reject-all'
function M.all(items, runner, action)
  if action == 'reject-all' then
    local insta = vim.tbl_filter(
      function(i) return i.kind == 'insta' end,
      items
    )
    if #insta == 0 then return notify('No pending insta snapshot to reject') end
    local answer = vim.fn.confirm(
      ('Delete all %d pending .snap.new files?'):format(#insta),
      '&Delete\n&Cancel',
      2
    )
    if answer ~= 1 then return end
    local failed = 0
    for _, item in ipairs(insta) do
      if not os.remove(item.file) then failed = failed + 1 end
    end
    return notify(
      ('%d rejected, %d failed'):format(#insta - failed, failed),
      failed > 0 and vim.log.levels.ERROR or nil
    )
  end
  -- One run per test file accepts every snapshot of it
  local files, seen = {}, {}
  for _, item in ipairs(items) do
    if item.kind == 'insta' or not seen[item.file] then
      seen[item.file] = true
      table.insert(files, item)
    end
  end
  local answer = vim.fn.confirm(
    ('Accept all %d pending snapshots (%d files)?'):format(#items, #files),
    '&Accept\n&Cancel',
    2
  )
  if answer ~= 1 then return end
  local failed = 0
  system.each(
    files,
    1,
    function(item, done)
      if item.kind == 'insta' then
        if not vim.uv.fs_rename(item.file, item.file:sub(1, -5)) then
          failed = failed + 1
        end
        return done()
      end
      local cmd = M.accept_command(runner --[[@as table]], item.file)
      system.run(
        cmd,
        { cwd = item.root, timeout = M.TIMEOUT, detach = true },
        function(result)
          if result.code ~= 0 then failed = failed + 1 end
          done()
        end
      )
    end,
    function()
      notify(
        ('%d of %d accepted'):format(#files - failed, #files),
        failed > 0 and vim.log.levels.ERROR or nil
      )
    end
  )
end

--- `:DySnapshots [accept-all|reject-all]`: pick a pending snapshot to
--- review, or act on all of them
---@param arg? string
function M.open(arg)
  if arg and arg ~= '' and arg ~= 'accept-all' and arg ~= 'reject-all' then
    return notify('Unknown argument: ' .. arg, vim.log.levels.ERROR)
  end
  local root = require('util.root').get()
  M.scan(root, function(items, runner)
    if not items then return end
    if #items == 0 then return notify('No pending snapshots') end
    if arg == 'accept-all' or arg == 'reject-all' then
      return M.all(items, runner, arg)
    end
    Snacks.picker.pick({
      title = 'Snapshots',
      items = M.picker_items(items),
      format = function(item)
        return {
          { item.snapshot.kind .. ' ', 'SnacksPickerComment' },
          { item.rel, 'SnacksPickerFile' },
          { '  ' },
          { item.snapshot.name, 'SnacksPickerLabel' },
        }
      end,
      preview = 'preview',
      confirm = function(picker, item)
        picker:close()
        if not item then return end
        M.session = {
          items = items,
          index = item.index,
          runner = runner,
        }
        M.show()
      end,
    })
  end)
end

return M
