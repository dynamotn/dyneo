--- The last pipeline of the branch, shown on the jobs of the file defining it
---
--- In a `.gitlab-ci.yml` or a GitHub Actions workflow, each job gets the
--- status of its last run on the current branch at the end of the line that
--- defines it: passed, failed, running, waiting or skipped. The forge is
--- asked through its own CLI (`util.forge`), which holds the token.
---
--- A GitLab file can also be checked by GitLab itself (`glab ci lint`),
--- which sends it to the server: never a file held back from AI, and only
--- once it is saved, since the file is what is sent.
local M = {}

local forge = require('util.forge')

local ns = vim.api.nvim_create_namespace('dy_ci')

---@alias DyCiBucket 'pass'|'fail'|'running'|'pending'|'skipped'|'attention'

--- What every status and conclusion of both forges comes down to
local BUCKETS = {
  success = 'pass',
  passed = 'pass',
  completed = 'pass',
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

--- Where each job of a pipeline file is defined, 1-based, by every name
--- its runs can carry
---@param lines string[]
---@param kind DyForgeKind
---@return table<string, integer>
function M.job_lines(lines, kind)
  local jobs = {}
  if kind == 'gitlab' then
    for number, line in ipairs(lines) do
      local key = key_of(line)
      if key and not GITLAB_KEYWORDS[key] and not key:match('^%.') then
        jobs[key] = number
      end
    end
    return jobs
  end

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
---@field id? integer
---@field name string
---@field status? string
---@field conclusion? string

---@class DyCiMark
---@field line integer 1-based
---@field bucket DyCiBucket
---@field count integer Runs of the job, matrix included

--- One mark per job line, the loudest of the runs defined there
---@param jobs DyCiJob[]
---@param lines table<string, integer> From `M.job_lines`
---@return DyCiMark[]
function M.marks(jobs, lines)
  local by_line = {}
  for _, job in ipairs(jobs) do
    local line = lines[job.name] or lines[M.defined_as(job.name)]
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

--- Which forge a pipeline file is for, by its filetype
---@param bufnr integer
---@return DyForgeKind?
function M.kind(bufnr)
  local ft = vim.bo[bufnr].filetype
  if ft == 'yaml.gitlab' then return 'gitlab' end
  if ft == 'yaml.gh-action' then return 'github' end
  return nil
end

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
---@field id integer
---@field status string
---@field url? string
---@field jobs DyCiJob[]

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

--- The last pipeline of `branch` for the file `file`, with its jobs
---@param remote DyForgeRemote
---@param branch string
---@param file string
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(remote, branch, file, on_done)
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
---@field kind DyForgeKind
---@field remote DyForgeRemote
---@field branch string

--- Hand `on_context` where the file of `bufnr` lives, and the forge and
--- branch it is on; say why and hand nothing when one is missing
---@param bufnr integer
---@param on_context fun(ctx: DyCiContext)
function M.context(bufnr, on_context)
  local kind = M.kind(bufnr)
  if not kind then
    return notify('Not a GitLab CI or GitHub Actions file', vim.log.levels.WARN)
  end
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then
    return notify('This buffer holds no file', vim.log.levels.WARN)
  end
  local dir = vim.fs.dirname(file)
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

--- Fetch and show the last pipeline of `ctx` on `bufnr`
---@param bufnr integer
---@param ctx DyCiContext
function M.show_status(bufnr, ctx)
  M.fetch(ctx.remote, ctx.branch, ctx.file, function(pipeline, err)
    if not vim.api.nvim_buf_is_valid(bufnr) then return end
    if not pipeline then return notify(err or 'failed', vim.log.levels.WARN) end
    local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
    local marks = M.marks(pipeline.jobs, M.job_lines(lines, ctx.kind))
    M.show(bufnr, marks)
    local bucket = M.bucket(pipeline.status)
    notify(
      ('%s %s %s on %s%s'):format(
        M.SYMBOLS[bucket],
        ctx.kind == 'gitlab' and 'Pipeline' or 'Run',
        pipeline.id,
        ctx.branch,
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
  if M.kind(bufnr) ~= 'gitlab' then
    return notify(
      'GitLab checks .gitlab-ci.yml; a workflow is checked by actionlint',
      vim.log.levels.WARN
    )
  end
  if require('util.sensitive').is_sensitive(bufnr) then
    return notify(
      'Held back from leaving the machine: not sent to GitLab',
      vim.log.levels.WARN
    )
  end
  if vim.bo[bufnr].modified then
    return notify('Write the file first: GitLab is sent what is saved')
  end
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
  vim.keymap.set(
    'n',
    '<localleader>s',
    function() M.status(bufnr) end,
    { buffer = bufnr, desc = 'Pipeline Status (CI)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>x',
    function() M.clear(bufnr) end,
    { buffer = bufnr, desc = 'Clear Status (CI)' }
  )
  vim.keymap.set(
    'n',
    '<localleader>e',
    function() require('tools.ai.ci').explain(bufnr) end,
    { buffer = bufnr, desc = 'Explain Failed Job (AI)' }
  )
  if M.kind(bufnr) == 'gitlab' then
    vim.keymap.set(
      'n',
      '<localleader>l',
      function() M.lint(bufnr) end,
      { buffer = bufnr, desc = 'Lint With GitLab (CI)' }
    )
  end
end

return M
