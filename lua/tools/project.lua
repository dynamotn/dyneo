--- One page for the state of the project: what to look at before starting
---
--- The branch and what is not pushed or committed, the diagnostics of the
--- open buffers, the tasks run, the open merge or pull requests, the last
--- pipeline of the branch and the Jira issues assigned. Each section fills
--- in on its own as its answer comes; one that cannot be had says why.
--- `<CR>` opens what the line is about, `r` asks everything again.
local M = {}

local forge = require('util.forge')
local scratch = require('util.scratch')

local ns = vim.api.nvim_create_namespace('dy_project')

--- How many items a section lists at most
M.LIMIT = 8

---@class DyProjectItem
---@field text string
---@field url? string Opened with `vim.ui.open`
---@field file? string Opened at `lnum`
---@field lnum? integer
---@field jira? string An issue key, opened by `tools.jira`

---@class DyProjectSection
---@field title string
---@field state 'loading'|'done'|'skipped'|'failed'
---@field note? string Why it was skipped or failed, or a summary
---@field items DyProjectItem[]

--- The order the sections are shown in
M.ORDER = { 'git', 'diagnostics', 'tasks', 'reviews', 'pipeline', 'jira' }

local TITLES = {
  git = 'Git',
  diagnostics = 'Diagnostics',
  tasks = 'Tasks',
  reviews = 'Merge requests',
  pipeline = 'Pipeline',
  jira = 'Jira',
}

--- A section waiting for its answer
---@param key string
---@return DyProjectSection
function M.section(key)
  return { title = TITLES[key] or key, state = 'loading', items = {} }
end

--- The lines of the page, and the item behind each line that has one
---@param root string
---@param sections table<string, DyProjectSection>
---@return string[] lines
---@return table<integer, DyProjectItem> items By 1-based line
---@return integer[] headings 1-based lines of the section titles
function M.render(root, sections)
  local lines = { 'Project ' .. vim.fn.fnamemodify(root, ':~') }
  local items, headings = {}, {}
  for _, key in ipairs(M.ORDER) do
    local section = sections[key]
    if section then
      table.insert(lines, '')
      local heading = section.title
      if section.state == 'loading' then
        heading = heading .. ' …'
      elseif section.note then
        heading = heading .. ' — ' .. section.note
      end
      table.insert(lines, heading)
      table.insert(headings, #lines)
      for index, item in ipairs(section.items) do
        if index > M.LIMIT then
          table.insert(
            lines,
            ('  … and %d more'):format(#section.items - M.LIMIT)
          )
          break
        end
        table.insert(lines, '  ' .. item.text)
        items[#lines] = item
      end
    end
  end
  return lines, items, headings
end

---@class DyProjectView
---@field root string
---@field sections table<string, DyProjectSection>
---@field items table<integer, DyProjectItem>
---@field generation integer Bumped on each refresh, so a late answer of an
--- earlier one is dropped

---@type table<integer, DyProjectView>
local views = {}

--- Show the sections of the view of `bufnr` as they are now
---@param bufnr integer
local function draw(bufnr)
  local view = views[bufnr]
  if not view or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines, items, headings = M.render(view.root, view.sections)
  view.items = items
  scratch.set(bufnr, lines)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  vim.api.nvim_buf_set_extmark(bufnr, ns, 0, 0, {
    end_row = 0,
    end_col = #lines[1],
    hl_group = 'Title',
  })
  for _, row in ipairs(headings) do
    vim.api.nvim_buf_set_extmark(bufnr, ns, row - 1, 0, {
      end_col = #lines[row],
      hl_group = 'Function',
    })
  end
end

--- Run `command` in `dir`, handing `on_done` its output lines, or nil and
--- why not
---@param command string[]
---@param dir string
---@param on_done fun(lines: string[]?, result: DyRunResult?)
---@param separator? string What the records end with, a newline unless given
local function run(command, dir, on_done, separator)
  require('util.system').run(
    command,
    { cwd = dir, timeout = forge.TIMEOUT },
    function(result)
      -- A list cut short would read as all there is
      if result.code ~= 0 or result.cut then return on_done(nil, result) end
      on_done(
        vim.split(
          result.stdout or '',
          separator or '\n',
          { plain = true, trimempty = true }
        )
      )
    end
  )
end

--- What a section's answer does: set it, unless a newer refresh started
---@param bufnr integer
---@param generation integer
---@param key string
---@return fun(state: string, note: string?, items: DyProjectItem[]?)
local function setter(bufnr, generation, key)
  return function(state, note, items)
    local view = views[bufnr]
    if not view or view.generation ~= generation then return end
    view.sections[key] = {
      title = TITLES[key],
      state = state,
      note = note,
      items = items or {},
    }
    draw(bufnr)
  end
end

--- The branch, what is ahead and behind its upstream, and what is changed
---@param root string
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
function M.git(root, set)
  -- `-z`: paths as they are, where a newline-separated list C-quotes one
  -- with a space or a non-ASCII letter
  local command = { 'git', 'status', '--porcelain=v1', '--branch', '-z' }
  run(command, root, function(lines, result)
    if not lines then
      -- git says so with exit 128; a timeout, a cut or no git is a failure
      if result and result.code == 128 and not result.timed_out then
        return set('skipped', 'not a git repository')
      end
      return set('failed', require('util.system').failure(result, 'git'))
    end
    local head = table.remove(lines, 1) or ''
    -- `## main...origin/main [ahead 1]`, `## main`, `## No commits yet on main`
    local branch = head:match('^## No commits yet on (%S+)')
      or head:match('^## (.-)%.%.%.')
      or head:match('^## (%S+)')
      or '?'
    local ahead = tonumber(head:match('ahead (%d+)')) or 0
    local behind = tonumber(head:match('behind (%d+)')) or 0
    local items = {}
    local index = 1
    while lines[index] do
      local line = lines[index]
      local file = line:sub(4)
      table.insert(items, {
        text = line:sub(1, 2) .. ' ' .. file,
        file = vim.fs.joinpath(root, file),
        lnum = 1,
      })
      -- A rename or a copy is followed by the path it came from
      index = index + (line:match('^[RC]') and 2 or 1)
    end
    set(
      'done',
      ('%s, %d ahead, %d behind, %d changed'):format(
        branch,
        ahead,
        behind,
        #items
      ),
      items
    )
  end, '\0')
end

--- The diagnostics of the loaded buffers under `root`, files with errors
--- first
---@param root string
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
function M.diagnostics(root, set)
  local severity = vim.diagnostic.severity
  local errors, warnings = 0, 0
  local per_file = {}
  for _, diagnostic in ipairs(vim.diagnostic.get(nil)) do
    local file = vim.api.nvim_buf_get_name(diagnostic.bufnr)
    if file ~= '' and vim.startswith(file, root .. '/') then
      local entry = per_file[file]
        or { file = file, errors = 0, warnings = 0, lnum = diagnostic.lnum + 1 }
      per_file[file] = entry
      if diagnostic.severity == severity.ERROR then
        if entry.errors == 0 then entry.lnum = diagnostic.lnum + 1 end
        entry.errors = entry.errors + 1
        errors = errors + 1
      elseif diagnostic.severity == severity.WARN then
        entry.warnings = entry.warnings + 1
        warnings = warnings + 1
      end
    end
  end
  local files = vim.tbl_values(per_file)
  table.sort(files, function(a, b)
    if a.errors ~= b.errors then return a.errors > b.errors end
    if a.warnings ~= b.warnings then return a.warnings > b.warnings end
    return a.file < b.file
  end)
  local items = {}
  for _, entry in ipairs(files) do
    table.insert(items, {
      text = ('%d errors, %d warnings  %s'):format(
        entry.errors,
        entry.warnings,
        vim.fn.fnamemodify(entry.file, ':~:.')
      ),
      file = entry.file,
      lnum = entry.lnum,
    })
  end
  set(
    'done',
    ('%d errors, %d warnings in open buffers'):format(errors, warnings),
    items
  )
end

--- The tasks overseer ran or is running, newest first
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
function M.tasks(set)
  local overseer = package.loaded.overseer
  if not overseer then return set('skipped', 'no task run yet') end
  local ok, tasks = pcall(overseer.list_tasks, { include_ephemeral = true })
  if not ok then return set('failed', 'overseer could not list its tasks') end
  local items = {}
  for _, task in ipairs(tasks) do
    table.insert(
      items,
      { text = ('%-9s %s'):format(task.status or '?', task.name or '?') }
    )
  end
  set('done', ('%d tasks'):format(#items), items)
end

--- What a dashboard without a forge says
local NO_FORGE = 'no GitHub, GitLab or Azure DevOps remote'

--- Runs of an Azure DevOps project looked through for the last one of the
--- repository: a project holds many, and its runs are asked for together
M.AZURE_RUNS = 20

--- The rows of an Azure DevOps list, `{ count, value }`
---@param data any
---@return table[]
local function azure_rows(data)
  return type(data) == 'table' and type(data.value) == 'table' and data.value
    or {}
end

--- The active pull requests of an Azure DevOps repository
---@param remote DyForgeRemote
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
local function azure_reviews(remote, set)
  forge.api(remote, {
    area = 'git',
    resource = 'pullRequests',
    route = { project = remote.project, repositoryId = remote.repo },
    query = {
      ['searchCriteria.status'] = 'active',
      ['$top'] = M.LIMIT + 1,
    },
  }, function(data, err)
    if not data then return set('failed', err) end
    local items = {}
    for _, row in ipairs(azure_rows(data)) do
      if type(row) == 'table' and row.pullRequestId then
        table.insert(items, {
          text = ('!%s %s'):format(
            tostring(row.pullRequestId),
            row.title or ''
          ),
          url = ('https://dev.azure.com/%s/%s/_git/%s/pullrequest/%s'):format(
            remote.org,
            forge.encode(remote.project),
            forge.encode(remote.repo),
            tostring(row.pullRequestId)
          ),
        })
      end
    end
    local count = #items > M.LIMIT and (M.LIMIT .. '+') or tostring(#items)
    set('done', ('%s open on %s'):format(count, remote.slug), items)
  end)
end

--- The last run on `branch` of any pipeline of an Azure DevOps repository
---@param remote DyForgeRemote
---@param branch string
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
local function azure_pipeline(remote, branch, set)
  local ci = require('tools.ci_inline')
  forge.api(remote, {
    area = 'build',
    resource = 'builds',
    route = { project = remote.project },
    query = {
      branchName = 'refs/heads/' .. branch,
      queryOrder = 'queueTimeDescending',
      ['$top'] = M.AZURE_RUNS,
    },
  }, function(data, err)
    if not data then return set('failed', err) end
    local last
    for _, row in ipairs(azure_rows(data)) do
      local repo = type(row) == 'table'
        and vim.tbl_get(row, 'repository', 'name')
      if type(repo) == 'string' and repo:lower() == remote.repo:lower() then
        last = row
        break
      end
    end
    if not last then return set('done', 'no pipeline on ' .. branch) end
    local bucket = ci.bucket(last.status, last.result)
    set('done', branch, {
      {
        text = ('%s %s %s'):format(
          ci.SYMBOLS[bucket],
          bucket,
          vim.tbl_get(last, 'definition', 'name') or ('#' .. tostring(last.id))
        ),
        url = vim.tbl_get(last, '_links', 'web', 'href'),
      },
    })
  end)
end

--- The open merge or pull requests of the forge of `root`
---@param remote DyForgeRemote?
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
function M.reviews(remote, set)
  if not remote then return set('skipped', NO_FORGE) end
  if remote.kind == 'azure' then return azure_reviews(remote, set) end
  local endpoint = remote.kind == 'github'
      and ('repos/%s/pulls?state=open&per_page=%d'):format(
        remote.slug,
        M.LIMIT + 1
      )
    or ('projects/%s/merge_requests?state=opened&per_page=%d'):format(
      forge.encode(remote.slug),
      M.LIMIT + 1
    )
  forge.api(remote, endpoint, function(rows, err)
    if not rows then return set('failed', err) end
    local items = {}
    for _, row in ipairs(type(rows) == 'table' and rows or {}) do
      local number = row.number or row.iid
      table.insert(items, {
        text = ('%s%s %s'):format(
          remote.kind == 'github' and '#' or '!',
          tostring(number),
          row.title or ''
        ),
        url = row.html_url or row.web_url,
      })
    end
    -- One more is asked for than is listed, to know there are more
    local count = #items > M.LIMIT and (M.LIMIT .. '+') or tostring(#items)
    set('done', ('%s open on %s'):format(count, remote.slug), items)
  end)
end

--- The last pipeline of `branch`, whichever workflow ran it
---@param remote DyForgeRemote?
---@param branch string?
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
function M.pipeline(remote, branch, set)
  if not remote then return set('skipped', NO_FORGE) end
  if not branch then return set('skipped', 'not on a branch') end
  if remote.kind == 'azure' then return azure_pipeline(remote, branch, set) end
  local ci = require('tools.ci_inline')
  local endpoint = remote.kind == 'github'
      and ('repos/%s/actions/runs?branch=%s&per_page=1'):format(
        remote.slug,
        forge.encode(branch)
      )
    or ('projects/%s/pipelines?ref=%s&per_page=1'):format(
      forge.encode(remote.slug),
      forge.encode(branch)
    )
  forge.api(remote, endpoint, function(data, err)
    if not data then return set('failed', err) end
    local last = remote.kind == 'github'
        and vim.tbl_get(data, 'workflow_runs', 1)
      or (type(data) == 'table' and data[1])
    if type(last) ~= 'table' then
      return set('done', 'no pipeline on ' .. branch)
    end
    local bucket = ci.bucket(last.status, last.conclusion)
    set('done', branch, {
      {
        text = ('%s %s %s'):format(
          ci.SYMBOLS[bucket],
          bucket,
          last.name or ('#' .. tostring(last.id))
        ),
        url = last.html_url or last.web_url,
      },
    })
  end)
end

--- The Jira issues assigned, through `tools.jira`
---@param set fun(state: string, note: string?, items: DyProjectItem[]?)
function M.jira(set)
  if vim.fn.executable('jira') ~= 1 then
    return set('skipped', 'the jira CLI is not installed')
  end
  local jira = require('tools.jira')
  jira.list(jira.DEFAULT_JQL, function(issues, err)
    if err then return set('failed', err) end
    local items = {}
    for _, issue in ipairs(issues) do
      table.insert(items, {
        text = ('%s [%s] %s'):format(issue.key, issue.status, issue.summary),
        jira = issue.key,
      })
    end
    set('done', ('%d assigned'):format(#items), items)
  end, { quiet = true })
end

--- Ask every section again
---@param bufnr integer
function M.refresh(bufnr)
  local view = views[bufnr]
  if not view then return end
  view.generation = view.generation + 1
  local generation = view.generation
  for _, key in ipairs(M.ORDER) do
    view.sections[key] = M.section(key)
  end
  draw(bufnr)

  local root = view.root
  M.git(root, setter(bufnr, generation, 'git'))
  M.diagnostics(root, setter(bufnr, generation, 'diagnostics'))
  M.tasks(setter(bufnr, generation, 'tasks'))
  M.jira(setter(bufnr, generation, 'jira'))
  forge.remote(root, function(remote)
    M.reviews(remote, setter(bufnr, generation, 'reviews'))
    forge.branch(
      root,
      function(branch)
        M.pipeline(remote, branch, setter(bufnr, generation, 'pipeline'))
      end
    )
  end)
end

--- Open what the line under the cursor is about
---@param bufnr integer
function M.activate(bufnr)
  local view = views[bufnr]
  local item = view and view.items[vim.api.nvim_win_get_cursor(0)[1]]
  if not item then return end
  if item.url then return vim.ui.open(item.url) end
  if item.jira then return require('tools.jira').open(item.jira) end
  if item.file then
    vim.cmd('tabprevious')
    vim.cmd.edit(vim.fn.fnameescape(item.file))
    pcall(vim.api.nvim_win_set_cursor, 0, { item.lnum or 1, 0 })
  end
end

--- Open the page of the project of the current buffer
---@return integer bufnr
function M.open()
  local root = vim.fs.root(0, { '.git' }) or vim.uv.cwd() --[[@as string]]
  local bufnr = scratch.open({}, {
    name = 'dyproject://' .. root,
    filetype = 'dyproject',
  })
  views[bufnr] = { root = root, sections = {}, items = {}, generation = 0 }
  vim.api.nvim_create_autocmd('BufWipeout', {
    buffer = bufnr,
    once = true,
    callback = function() views[bufnr] = nil end,
  })
  vim.keymap.set(
    'n',
    '<cr>',
    function() M.activate(bufnr) end,
    { buffer = bufnr, desc = 'Open (Project)' }
  )
  vim.keymap.set(
    'n',
    'r',
    function() M.refresh(bufnr) end,
    { buffer = bufnr, desc = 'Refresh (Project)', nowait = true }
  )
  M.refresh(bufnr)
  return bufnr
end

return M
