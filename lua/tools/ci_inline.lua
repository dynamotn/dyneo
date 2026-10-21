--- The last pipeline of the branch, shown on the jobs of the file defining it
---
--- In a `.gitlab-ci.yml`, a GitHub Actions workflow or an Azure Pipelines
--- file, each job gets the status of its last run on the current branch at
--- the end of the line that defines it: passed, failed, running, waiting or
--- skipped. The forge is asked through its own CLI (`util.forge`), which
--- holds the token. A `Jenkinsfile` gets its stages from the job its clone
--- names (`tools.ci_jenkins`), an Argo workflow its steps from the current
--- kubectl context (`tools.ci_argo`).
---
--- A GitLab file or a Jenkinsfile can also be checked by its server, which
--- is sent the file: never a file held back from AI, and only once it is
--- saved, since the file is what is sent.
local M = {}

local forge = require('util.forge')

local ns = vim.api.nvim_create_namespace('dy_ci')

---@alias DyCiBucket 'pass'|'fail'|'running'|'pending'|'skipped'|'attention'

--- What every status and conclusion of the forges comes down to, lower case
local BUCKETS = {
  success = 'pass',
  passed = 'pass',
  completed = 'pass',
  succeeded = 'pass',
  -- Azure: a step marked `continueOnError` failed, or one warned
  succeededwithissues = 'pass',
  partiallysucceeded = 'attention',
  inprogress = 'running',
  cancelling = 'running',
  notstarted = 'pending',
  postponed = 'pending',
  abandoned = 'skipped',
  -- Jenkins: tests failed in a build that ran to its end
  unstable = 'attention',
  paused_pending_input = 'pending',
  aborted = 'skipped',
  not_executed = 'skipped',
  not_built = 'skipped',
  -- Argo
  error = 'fail',
  omitted = 'skipped',
  -- Airflow: a task an upstream failure kept from running did not fail
  upstream_failed = 'skipped',
  up_for_retry = 'running',
  up_for_reschedule = 'pending',
  restarting = 'running',
  deferred = 'pending',
  removed = 'skipped',
  awaiting_input = 'attention',
  none = 'pending',
  -- Prefect
  crashed = 'fail',
  paused = 'attention',
  -- Dagster
  started = 'running',
  starting = 'pending',
  not_started = 'pending',
  managed = 'pending',
  suspended = 'attention',
  failure = 'fail',
  failed = 'fail',
  timed_out = 'fail',
  startup_failure = 'fail',
  action_required = 'attention',
  in_progress = 'running',
  running = 'running',
  canceling = 'running',
  queued = 'pending',
  requested = 'pending',
  waiting = 'pending',
  waiting_for_resource = 'pending',
  pending = 'pending',
  created = 'pending',
  preparing = 'pending',
  scheduled = 'pending',
  manual = 'pending',
  skipped = 'skipped',
  neutral = 'skipped',
  cancelled = 'skipped',
  canceled = 'skipped',
}

--- How loud each bucket is, loudest first
local RANK =
  { fail = 1, attention = 2, running = 3, pending = 4, pass = 5, skipped = 6 }

M.SYMBOLS = {
  pass = '✓',
  fail = '✗',
  running = '●',
  pending = '○',
  skipped = '⊘',
  attention = '!',
}

local HIGHLIGHTS = {
  pass = 'DiagnosticOk',
  fail = 'DiagnosticError',
  running = 'DiagnosticInfo',
  pending = 'Comment',
  skipped = 'Comment',
  attention = 'DiagnosticWarn',
}

--- The bucket of a job: its conclusion once there is one, else its status.
--- An unknown value is pending, never passed.
---@param status? string
---@param conclusion? string
---@return DyCiBucket
function M.bucket(status, conclusion)
  -- Not a list: a missing conclusion would end it before the status
  local value = (type(conclusion) == 'string' and conclusion ~= '')
      and conclusion
    or status
  if type(value) ~= 'string' or value == '' then return 'pending' end
  return BUCKETS[value:lower()] or 'pending'
end

--- The top-level keys of a `.gitlab-ci.yml` that are not jobs
local GITLAB_KEYWORDS = {
  default = true,
  include = true,
  stages = true,
  variables = true,
  workflow = true,
  image = true,
  services = true,
  cache = true,
  before_script = true,
  after_script = true,
  spec = true,
}

--- A YAML key at the start of `line`, quoted or not, and what follows it
---@param line string
---@return string? key
---@return string? rest
local function key_of(line)
  local key, rest = line:match('^"([^"]+)"%s*:(.*)$')
  if not key then
    key, rest = line:match("^'([^']+)'%s*:(.*)$")
  end
  if not key then
    key, rest = line:match('^([^%s#"\'][^:#]-)%s*:(.*)$')
  end
  if not key then return nil end
  -- `a: b` on a key that is a job opens a mapping, an anchor or a comment
  rest = vim.trim(rest)
  if rest ~= '' and not rest:match('^&') and not rest:match('^#') then
    return key, rest
  end
  return key, ''
end

--- A YAML scalar without its comment and quotes
---@param value string
---@return string
local function scalar(value)
  value = vim.trim((value:gsub('%s+#.*$', '')))
  return (value:gsub('^(["\'])(.*)%1$', '%2'))
end

--- Where each job of an Azure Pipelines file is defined, by its name and
--- its `displayName`: the items `- job:` and `- deployment:`, wherever they
--- sit. A file of `steps:` alone runs one job, called `Job`.
---@param lines string[]
---@return table<string, integer>
function M.azure_job_lines(lines)
  local jobs, current, column, steps = {}, nil, nil, nil
  for number, line in ipairs(lines) do
    if line:match('^%s*#') or not line:match('%S') then goto continue end
    local dash, key, value = line:match('^(%s*%-%s+)(%a+)%s*:(.*)$')
    if dash and (key == 'job' or key == 'deployment') then
      current, column = scalar(value), #dash
      if current == '' then
        current = nil
      else
        jobs[current] = number
      end
    else
      local indent = #line:match('^(%s*)')
      if current and indent < column then current = nil end
      local display = current
        and indent == column
        and line:match('^%s*displayName%s*:(.*)$')
      if display and scalar(display) ~= '' then
        jobs[scalar(display)] = jobs[current]
      end
      if line:match('^steps%s*:') then steps = number end
    end
    ::continue::
  end
  if steps and next(jobs) == nil then jobs.Job = steps end
  return jobs
end

--- The module that asks each system that is no forge
M.MODULES = {
  jenkins = 'tools.ci_jenkins',
  argo = 'tools.ci_argo',
  airflow = 'tools.ci_airflow',
  prefect = 'tools.ci_prefect',
  dagster = 'tools.ci_dagster',
}

--- The systems whose pipelines are Python files: their mappings sit under
--- `<localleader>p`, since Python's own `<localleader>s` sends to a REPL
M.PYTHON = { airflow = true, prefect = true, dagster = true }

--- Where each job of a pipeline file is defined, 1-based, by every name
--- its runs can carry
---@param lines string[]
---@param kind DyCiKind
---@return table<string, integer>
function M.job_lines(lines, kind)
  local jobs = {}
  if M.MODULES[kind] then return require(M.MODULES[kind]).job_lines(lines) end
  if kind == 'gitlab' then
    for number, line in ipairs(lines) do
      local key = key_of(line)
      if key and not GITLAB_KEYWORDS[key] and not key:match('^%.') then
        jobs[key] = number
      end
    end
    return jobs
  end
  if kind == 'azure' then return M.azure_job_lines(lines) end

  -- GitHub: the keys right under `jobs:`, and the `name:` each may have
  local in_jobs, child, current, property = false, nil, nil, nil
  for number, line in ipairs(lines) do
    if line:match('^#') then
      -- A comment, wherever it starts, ends nothing
      goto continue
    elseif line:match('^%S') then
      in_jobs = line:match('^jobs%s*:%s*$') ~= nil
      current = nil
    elseif in_jobs and line:match('%S') and not line:match('^%s*#') then
      local indent = #line:match('^(%s*)')
      child = child or indent
      if indent == child then
        current = key_of(line:sub(indent + 1))
        property = nil
        if current then jobs[current] = number end
      elseif current then
        property = property or indent
        local name = indent == property
          and line:sub(indent + 1):match('^name%s*:%s*(.-)%s*$')
        if name and name ~= '' then
          name = name:gsub('^["\']', ''):gsub('["\']$', '')
          jobs[name] = jobs[current]
        end
      end
    end
    ::continue::
  end
  return jobs
end

--- The name a job of a run is defined under: without the matrix values of
--- `build (ubuntu, 22)` (GitHub) or `deploy: [aws, eu]` (GitLab), the index
--- of a GitLab `parallel` job in `rspec 1/3`, and the caller of a reusable
--- workflow in `ci / test`
---@param name string
---@return string
function M.defined_as(name)
  name = name:gsub('%s+%b()$', '')
  name = name:gsub(':%s*%b[]$', '')
  name = name:gsub('%s+%d+/%d+$', '')
  return (name:gsub('%s+/%s+.*$', ''))
end

---@class DyCiJob
---@field id? integer|string What the job's log is asked for by
---@field name string
---@field template? string Argo: the template the step runs
---@field status? string
---@field conclusion? string
---@field try? integer Airflow: the try whose log is read
---@field map_index? integer Airflow: a mapped task's index, `-1` if not one

---@class DyCiMark
---@field line integer 1-based
---@field bucket DyCiBucket
---@field count integer Runs of the job, matrix included

--- One mark per job line, the loudest of the runs defined there
---@param jobs DyCiJob[]
---@param lines table<string, integer> From `M.job_lines`
---@param kind? DyCiKind
---@return DyCiMark[]
function M.marks(jobs, lines, kind)
  local by_line = {}
  for _, job in ipairs(jobs) do
    local line = lines[job.name] or lines[M.defined_as(job.name)]
    -- Azure names a leg of a matrix after its job: `Build linux`
    if not line and kind == 'azure' then
      line = lines[job.name:match('^(.-)%s+%S+$') or '']
    end
    -- Airflow names a mapped instance `task[2]`, and a task of a group
    -- `group.task`; Prefect a task's run `task-0`
    if not line and kind == 'airflow' then
      local id = job.name:gsub('%[%d+%]$', '')
      line = lines[id] or lines[id:match('([^.]+)$') or '']
    end
    if not line and kind == 'prefect' then
      line = lines[job.name:match('^(.-)%-[%w]+$') or '']
    end
    -- Argo names a retry or a loop item after its step, `build(0:linux)`,
    -- and a step it reached through another template after that template
    if not line and kind == 'argo' then
      line = lines[(job.name:gsub('%b()$', ''))]
        or (job.template and lines[job.template])
    end
    if line then
      local bucket = M.bucket(job.status, job.conclusion)
      local mark = by_line[line]
      if not mark then
        by_line[line] = { line = line, bucket = bucket, count = 1 }
      else
        mark.count = mark.count + 1
        if RANK[bucket] < RANK[mark.bucket] then mark.bucket = bucket end
      end
    end
  end
  local marks = vim.tbl_values(by_line)
  table.sort(marks, function(a, b) return a.line < b.line end)
  return marks
end

--- The text a mark shows
---@param mark DyCiMark
---@return string
function M.text(mark)
  local text = M.SYMBOLS[mark.bucket] .. ' ' .. mark.bucket
  if mark.count > 1 then text = text .. (' ×%d'):format(mark.count) end
  return text
end

local notify = require('util.notify').titled('CI')

--- Which CI system a pipeline file is for
---@param bufnr integer
---@return DyCiKind?
function M.kind(bufnr) return require('util.ci_kind').of(bufnr) end

--- Put `marks` on `bufnr`
---@param bufnr integer
---@param marks DyCiMark[]
function M.show(bufnr, marks)
  vim.api.nvim_buf_clear_namespace(bufnr, ns, 0, -1)
  local count = vim.api.nvim_buf_line_count(bufnr)
  for _, mark in ipairs(marks) do
    if mark.line <= count then
      vim.api.nvim_buf_set_extmark(bufnr, ns, mark.line - 1, 0, {
        virt_text = { { '  ' .. M.text(mark), HIGHLIGHTS[mark.bucket] } },
        virt_text_pos = 'eol',
      })
    end
  end
end

--- Forget the statuses shown on `bufnr`
---@param bufnr? integer
function M.clear(bufnr) vim.api.nvim_buf_clear_namespace(bufnr or 0, ns, 0, -1) end

---@class DyCiPipeline
---@field id integer|string A build number, or an Argo run's name
---@field status string
---@field url? string
---@field jobs DyCiJob[]
---@field note? string Why the jobs are not all there is to see
---@field run_id? string Prefect: the flow run's id, its name being shown

--- Jobs a forge hands over per page, the most both of them allow
M.PER_PAGE = 100

--- How many pages of jobs are read before giving up on a run
M.MAX_PAGES = 10

--- Every job at `path`, read a page at a time: one page alone could leave out
--- the very job that failed, and read as a clean run
---@param remote DyForgeRemote
---@param path string
---@param rows_of fun(data: any): table[]
---@param on_done fun(rows: table[]?, err: string?)
local function all_jobs(remote, path, rows_of, on_done)
  local rows = {}
  local function page(index)
    local url = ('%s?per_page=%d&page=%d'):format(path, M.PER_PAGE, index)
    forge.api(remote, url, function(data, err)
      if not data then return on_done(nil, err) end
      local got = rows_of(data)
      vim.list_extend(rows, got)
      if #got < M.PER_PAGE then return on_done(rows) end
      if index >= M.MAX_PAGES then
        return on_done(
          nil,
          ('More than %d jobs: not all of them could be read'):format(#rows)
        )
      end
      page(index + 1)
    end)
  end
  page(1)
end

--- The rows of an Azure DevOps list, `{ count, value }`
---@param data any
---@return table[]
local function azure_rows(data)
  return type(data) == 'table' and type(data.value) == 'table' and data.value
    or {}
end

--- The pipeline of `remote`'s project that runs `path` from `remote`'s
--- repository. Azure keeps a file's name with or without a leading slash,
--- and filters by it as kept: both spellings are asked.
---@param remote DyForgeRemote
---@param path string The file, relative to the root of its repository
---@param on_done fun(definition: table?, err: string?)
function M.azure_definition(remote, path, on_done)
  local function runs_here(row)
    local repo = vim.tbl_get(row, 'repository', 'name')
    local yaml = vim.tbl_get(row, 'process', 'yamlFilename')
    return type(repo) == 'string'
      and repo:lower() == remote.repo:lower()
      and type(yaml) == 'string'
      and (yaml:gsub('^/', '')) == path
  end
  local spellings = { path, '/' .. path }
  local function ask(index)
    if not spellings[index] then
      return on_done(
        nil,
        ('No pipeline of %s runs %s'):format(remote.project, path)
      )
    end
    forge.api(remote, {
      area = 'build',
      resource = 'definitions',
      route = { project = remote.project },
      query = { yamlFilename = spellings[index], includeAllProperties = 'true' },
    }, function(data, err)
      if not data then return on_done(nil, err) end
      for _, row in ipairs(azure_rows(data)) do
        if type(row) == 'table' and runs_here(row) then return on_done(row) end
      end
      ask(index + 1)
    end)
  end
  ask(1)
end

--- The last run on `branch` of the Azure pipeline defined by `file`, with
--- the jobs of its timeline
---@param remote DyForgeRemote
---@param branch string
---@param file string
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
local function fetch_azure(remote, branch, file, on_done)
  local root = vim.fs.root(file, '.git')
  local path = root and vim.fs.relpath(root, file)
  if not path then return on_done(nil, 'Not in a git repository') end
  M.azure_definition(remote, path, function(definition, err)
    if not definition then return on_done(nil, err) end
    forge.api(remote, {
      area = 'build',
      resource = 'builds',
      route = { project = remote.project },
      query = {
        definitions = definition.id,
        branchName = 'refs/heads/' .. branch,
        queryOrder = 'queueTimeDescending',
        ['$top'] = 1,
      },
    }, function(data, e)
      if not data then return on_done(nil, e) end
      local last = azure_rows(data)[1]
      if type(last) ~= 'table' or not last.id then
        return on_done(
          nil,
          ('No run of %s on %s'):format(definition.name or path, branch)
        )
      end
      local pipeline = {
        id = last.id,
        status = last.result or last.status,
        url = vim.tbl_get(last, '_links', 'web', 'href'),
        jobs = {},
      }
      -- A run still queued has no timeline yet
      if last.status == 'notStarted' then return on_done(pipeline) end
      forge.api(remote, {
        area = 'build',
        resource = 'timeline',
        route = { project = remote.project, buildId = last.id },
      }, function(timeline, e2)
        if not timeline then return on_done(nil, e2) end
        local records = type(timeline) == 'table' and timeline.records
        for _, record in ipairs(type(records) == 'table' and records or {}) do
          if
            type(record) == 'table'
            and record.type == 'Job'
            and type(record.name) == 'string'
          then
            table.insert(pipeline.jobs, {
              -- The log is what a job is asked for by
              id = vim.tbl_get(record, 'log', 'id'),
              name = record.name,
              status = record.state,
              conclusion = record.result,
            })
          end
        end
        on_done(pipeline)
      end)
    end)
  end)
end

--- The last pipeline of `branch` for the file `file`, with its jobs
---@param remote DyForgeRemote
---@param branch string
---@param file string
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(remote, branch, file, on_done)
  if remote.kind == 'azure' then
    return fetch_azure(remote, branch, file, on_done)
  end
  if remote.kind == 'gitlab' then
    local project = 'projects/' .. forge.encode(remote.slug)
    local runs = ('%s/pipelines?ref=%s&per_page=1'):format(
      project,
      forge.encode(branch)
    )
    return forge.api(remote, runs, function(data, err)
      if not data then return on_done(nil, err) end
      local last = type(data) == 'table' and data[1]
      if type(last) ~= 'table' or not last.id then
        return on_done(nil, 'No pipeline on ' .. branch)
      end
      local jobs = ('%s/pipelines/%d/jobs'):format(project, last.id)
      local function rows_of(data) return type(data) == 'table' and data or {} end
      all_jobs(remote, jobs, rows_of, function(rows, e)
        if not rows then return on_done(nil, e) end
        on_done({
          id = last.id,
          status = last.status,
          url = last.web_url,
          jobs = vim.tbl_map(
            function(row)
              return { id = row.id, name = row.name, status = row.status }
            end,
            rows
          ),
        })
      end)
    end)
  end

  local runs = ('repos/%s/actions/workflows/%s/runs?branch=%s&per_page=1'):format(
    remote.slug,
    forge.encode(vim.fs.basename(file)),
    forge.encode(branch)
  )
  forge.api(remote, runs, function(data, err)
    if not data then return on_done(nil, err) end
    local last = vim.tbl_get(data, 'workflow_runs', 1)
    if type(last) ~= 'table' or not last.id then
      return on_done(nil, 'No run of this workflow on ' .. branch)
    end
    local jobs = ('repos/%s/actions/runs/%d/jobs'):format(remote.slug, last.id)
    local function rows_of(data)
      return type(data) == 'table' and type(data.jobs) == 'table' and data.jobs
        or {}
    end
    all_jobs(remote, jobs, rows_of, function(rows, e)
      if not rows then return on_done(nil, e) end
      on_done({
        id = last.id,
        status = last.conclusion or last.status,
        url = last.html_url,
        jobs = vim.tbl_map(
          function(row)
            return {
              id = row.id,
              name = row.name,
              status = row.status,
              conclusion = row.conclusion,
            }
          end,
          rows
        ),
      })
    end)
  end)
end

---@class DyCiContext
---@field dir string
---@field file string
---@field kind DyCiKind
---@field remote? DyForgeRemote The forge, for GitHub, GitLab and Azure
---@field target? DyJenkinsTarget|DyArgoTarget|DyAirflowTarget|DyPrefectTarget|DyDagsterTarget What else is asked
---@field branch? string The branch, for a forge and Jenkins
---@field where? string What a run is of, shown when no branch is

--- The definition `bufnr`'s cursor is in or below, else the first
---@param bufnr integer
---@param defs { id: string, line: integer }[] In the order of their lines
---@return { id: string, line: integer }
function M.at_cursor(bufnr, defs)
  local chosen = defs[1]
  if bufnr == vim.api.nvim_get_current_buf() then
    local row = vim.api.nvim_win_get_cursor(0)[1]
    for _, def in ipairs(defs) do
      if def.line <= row then chosen = def end
    end
  end
  return chosen
end

--- What a data pipeline's file defines that runs: DAGs, flows or jobs
local DEFINITIONS = {
  airflow = { 'dags', 'No DAG in this file' },
  prefect = { 'flows', 'No @flow in this file' },
  dagster = { 'jobs', 'No job or asset in this file' },
}

--- Hand `on_context` where the file of `bufnr` lives, and the forge and
--- branch it is on; say why and hand nothing when one is missing
---@param bufnr integer
---@param on_context fun(ctx: DyCiContext)
function M.context(bufnr, on_context)
  local kind = M.kind(bufnr)
  if not kind then
    return notify(
      'Not a pipeline file of a CI or data pipeline DyNeo knows',
      vim.log.levels.WARN
    )
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  local dir = vim.fs.dirname(file)
  local function failed(err) notify(err, vim.log.levels.WARN) end
  if kind == 'argo' then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    return require('tools.ci_argo').target(dir, lines, function(target, err)
      if not target then return failed(err) end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      on_context({
        dir = dir,
        file = file,
        kind = kind,
        target = target,
        where = ('%s/%s'):format(target.context, target.namespace),
      })
    end)
  end
  if M.PYTHON[kind] then
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local module = require(M.MODULES[kind])
    local list, none = unpack(DEFINITIONS[kind])
    local defs = module[list](lines)
    -- Assets no job of the file names run in Dagster's own asset job
    if #defs == 0 and kind == 'dagster' and module.has_assets(lines) then
      defs = { { id = module.ASSET_JOB, line = 1 } }
    end
    if #defs == 0 then return failed(none) end
    local chosen = M.at_cursor(bufnr, defs)
    -- Prefect looks for the project's `.venv` there
    local root = kind == 'prefect'
        and vim.fs.root(file, { '.venv', 'pyproject.toml', '.git' })
      or dir
    return module.target(root, chosen.id, function(target, err)
      if not target then return failed(err) end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      on_context({
        dir = dir,
        file = file,
        kind = kind,
        target = target,
        where = chosen.id,
      })
    end)
  end
  if kind == 'jenkins' then
    return forge.branch(dir, function(branch)
      if not branch then return failed('Not on a branch') end
      require('tools.ci_jenkins').target(dir, branch, function(target, err)
        if not target then return failed(err) end
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        on_context({
          dir = dir,
          file = file,
          kind = kind,
          target = target,
          branch = branch,
        })
      end)
    end)
  end
  forge.remote(dir, function(remote)
    if not remote or remote.kind ~= kind then
      return notify(
        ('No %s remote in %s'):format(kind, table.concat(forge.REMOTES, ', ')),
        vim.log.levels.WARN
      )
    end
    forge.branch(dir, function(branch)
      if not branch then
        return notify('Not on a branch', vim.log.levels.WARN)
      end
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      on_context({
        dir = dir,
        file = file,
        kind = kind,
        remote = remote,
        branch = branch,
      })
    end)
  end)
end

--- Show the last pipeline of the branch on the jobs of the current buffer
---@param bufnr? integer
function M.status(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  M.context(bufnr, function(ctx) M.show_status(bufnr, ctx) end)
end

--- The last pipeline of `ctx`, from whichever system runs it
---@param ctx DyCiContext
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch_for(ctx, on_done)
  if M.MODULES[ctx.kind] then
    return require(M.MODULES[ctx.kind]).fetch(ctx.target, on_done)
  end
  M.fetch(ctx.remote, ctx.branch, ctx.file, on_done)
end

--- What a run is called, by the system that ran it
local RUN_NAMES = {
  gitlab = 'Pipeline',
  jenkins = 'Build',
  argo = 'Workflow',
  airflow = 'DAG run',
  prefect = 'Flow run',
}

--- Fetch and show the last pipeline of `ctx` on `bufnr`
---@param bufnr integer
---@param ctx DyCiContext
function M.show_status(bufnr, ctx)
  M.fetch_for(ctx, function(pipeline, err)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not pipeline then return notify(err or 'failed', vim.log.levels.WARN) end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local marks = M.marks(pipeline.jobs, M.job_lines(lines, ctx.kind), ctx.kind)
    M.show(bufnr, marks)
    local bucket = M.bucket(pipeline.status)
    local where = ctx.branch or ctx.where or '?'
    notify(
      ('%s %s %s on %s%s%s'):format(
        M.SYMBOLS[bucket],
        RUN_NAMES[ctx.kind] or 'Run',
        pipeline.id,
        where,
        pipeline.note and ('\n' .. pipeline.note) or '',
        pipeline.url and ('\n' .. pipeline.url) or ''
      ),
      bucket == 'fail' and vim.log.levels.WARN or nil
    )
  end)
end

--- The problems `glab ci lint` printed, as diagnostics: on the job they
--- name, else on the first line
---@param output string
---@param lines string[]
---@return vim.Diagnostic[]
function M.lint_diagnostics(output, lines)
  local jobs = M.job_lines(lines, 'gitlab')
  local diagnostics = {}
  for line in output:gmatch('[^\n]+') do
    local message = line:match('^%s*%d+%s+(.+)$')
    if message then
      local job = message:match('jobs:([^%s:]+)')
      local lnum = job and jobs[job] and (jobs[job] - 1) or 0
      table.insert(diagnostics, {
        lnum = lnum,
        col = 0,
        message = message,
        severity = vim.diagnostic.severity.ERROR,
        source = 'gitlab ci lint',
      })
    end
  end
  return diagnostics
end

local lint_ns = vim.api.nvim_create_namespace('dy_ci_lint')

--- Have GitLab check the saved `.gitlab-ci.yml` of the current buffer
---@param bufnr? integer
function M.lint(bufnr)
  bufnr = (bufnr == nil or bufnr == 0) and vim.api.nvim_get_current_buf()
    or bufnr
  local kind = M.kind(bufnr)
  if kind ~= 'gitlab' and kind ~= 'jenkins' then
    return notify(
      'GitLab checks .gitlab-ci.yml and Jenkins a Jenkinsfile; a workflow is checked as it is edited',
      vim.log.levels.WARN
    )
  end
  local server = kind == 'gitlab' and 'GitLab' or 'Jenkins'
  if require('util.sensitive').is_sensitive(bufnr) then
    return notify(
      'Held back from leaving the machine: not sent to ' .. server,
      vim.log.levels.WARN
    )
  end
  if vim.bo[bufnr].modified then
    return notify(
      ('Write the file first: %s is sent what is saved'):format(server)
    )
  end
  if kind == 'jenkins' then return M.lint_jenkins(bufnr) end
  if vim.fn.executable('glab') ~= 1 then
    return notify('glab is not installed', vim.log.levels.ERROR)
  end
  M.context(bufnr, function(ctx)
    local opts = { cwd = ctx.dir, timeout = forge.TIMEOUT }
    -- `glab` sends the file to the remote's host, which the repository
    -- names: a token from the environment stays with the host it is for
    local env = forge.cli_env(ctx.remote)
    if env then
      opts.env, opts.clear_env = env, true
    end
    require('util.system').run(
      { 'glab', 'ci', 'lint', ctx.file },
      opts,
      function(result)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        local output = (result.stdout or '') .. '\n' .. (result.stderr or '')
        -- An answer that never came, came cut, or came empty says nothing
        -- about the file: it is reported as a failure, not as a problem in it
        if
          result.timed_out
          or result.cut
          or result.missing
          or (result.code ~= 0 and vim.trim(output) == '')
        then
          return notify(
            require('util.system').failure(result, 'glab ci lint'),
            vim.log.levels.ERROR
          )
        end
        local diagnostics = M.lint_diagnostics(
          output,
          vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
        )
        if result.code ~= 0 and #diagnostics == 0 then
          diagnostics = {
            {
              lnum = 0,
              col = 0,
              message = vim.trim(output),
              severity = vim.diagnostic.severity.ERROR,
              source = 'gitlab ci lint',
            },
          }
        end
        vim.diagnostic.set(lint_ns, bufnr, diagnostics)
        notify(
          #diagnostics == 0 and 'GitLab says the file is valid'
            or ('GitLab found %d problems'):format(#diagnostics),
          #diagnostics > 0 and vim.log.levels.WARN or nil
        )
      end
    )
  end)
end

--- Have the Jenkins server of a saved Jenkinsfile check it
---@param bufnr integer
function M.lint_jenkins(bufnr)
  M.context(bufnr, function(ctx)
    local text =
      table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), '\n')
    require('tools.ci_jenkins').lint(
      ctx.target.url,
      text .. '\n',
      function(diagnostics, err)
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        if err then return notify(err, vim.log.levels.WARN) end
        vim.diagnostic.set(lint_ns, bufnr, diagnostics or {})
        notify(
          not diagnostics and 'Jenkins says the file is valid'
            or ('Jenkins found %d problems'):format(#diagnostics),
          diagnostics and vim.log.levels.WARN or nil
        )
      end
    )
  end)
end

--- The subcommands of `:Ci`-style commands
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1]
  if sub == 'clear' then return M.clear(0) end
  if sub then
    return notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
  end
  M.status(0)
end

--- The mappings of a pipeline file
---@param bufnr integer
function M.attach(bufnr)
  local kind = M.kind(bufnr)
  local prefix = M.PYTHON[kind] and '<localleader>p' or '<localleader>'
  if M.PYTHON[kind] and package.loaded['which-key'] then
    pcall(
      require('which-key').add,
      { { prefix, group = 'pipeline', buffer = bufnr } }
    )
  end
  vim.keymap.set(
    'n',
    prefix .. 's',
    function() M.status(bufnr) end,
    { buffer = bufnr, desc = 'Pipeline Status (CI)' }
  )
  vim.keymap.set(
    'n',
    prefix .. 'x',
    function() M.clear(bufnr) end,
    { buffer = bufnr, desc = 'Clear Status (CI)' }
  )
  vim.keymap.set(
    'n',
    prefix .. 'e',
    function() require('tools.ai.ci').explain(bufnr) end,
    { buffer = bufnr, desc = 'Explain Failed Job (AI)' }
  )
  if kind == 'gitlab' or kind == 'jenkins' then
    vim.keymap.set('n', '<localleader>l', function() M.lint(bufnr) end, {
      buffer = bufnr,
      desc = kind == 'gitlab' and 'Lint With GitLab (CI)'
        or 'Lint With Jenkins (CI)',
    })
  end
end

return M
