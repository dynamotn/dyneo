--- The CI state of a pull request's head, for the review panel
---
--- Reads and links, nothing more: logs stay with the CI tools. Forge runs are
--- keyed by the head commit; Jenkins and Argo know no commit, so they are
--- asked for the head branch (Argo for the workflow's name) and marked so.
--- Both are asked only when their target resolves. Jenkins' reads the clone's
--- config, so a held worktree is no reason to skip it; Argo's names come from
--- a file of the pull request and name what the reviewer's cluster is asked,
--- so it waits for trust.
local M = {}

local forge = require('util.forge')
local system = require('util.system')

--- Sources asked at once
M.CONCURRENCY = 3

--- Milliseconds a source has to answer, a little over the longest CLI call
M.SOURCE_TIMEOUT = forge.TIMEOUT + 5000

--- What the header says of a source held back until the code is trusted
M.WAIT_FOR_TRUST = 'after you trust the PR'

--- Workflow files of the pull request looked at for an Argo workflow
M.ARGO_CANDIDATES = 20

--- Lines of such a file read, as far as the kind is told
M.ARGO_LINES = 40

--- The order the header counts the states in
M.STATES = { 'pass', 'fail', 'running', 'pending', 'skipped', 'attention' }

---@class DyReviewCiRun
---@field provider 'github'|'gitlab'|'azure'|'jenkins'|'argo'
---@field name string
---@field state 'pass'|'fail'|'running'|'pending'|'skipped'|'attention'
---@field url? string
---@field by 'commit'|'branch'|'name' What the status is keyed on: the head, the head branch, or the workflow's name

---@class DyReviewCi
---@field runs DyReviewCiRun[]
---@field errors string[] `<source>: <reason>`, one per source that gave no answer
---@field waiting? string[] `<source>: <reason>`, sources not asked yet

---@alias DyReviewCiSource fun(done: fun(runs?: DyReviewCiRun[], err?: string, waiting?: string))

--- The bucket of a status and conclusion
---@param status? string
---@param conclusion? string
---@return string
local function bucket(status, conclusion)
  return require('tools.ci_inline').bucket(status, conclusion)
end

--- GitHub: the check runs of the head commit
---@param s DyReviewSession
---@return DyReviewCiSource
local function github(s)
  return function(done)
    local path = ('repos/%s/commits/%s/check-runs?per_page=100'):format(
      s.remote.slug,
      s.pull.head_sha
    )
    forge.api(s.remote, path, function(data, err)
      local rows = type(data) == 'table' and data.check_runs
      if type(rows) ~= 'table' then return done(nil, err or 'no check runs') end
      local runs = {}
      for _, row in ipairs(rows) do
        runs[#runs + 1] = {
          provider = 'github',
          name = tostring(row.name),
          state = bucket(row.status, row.conclusion),
          url = row.html_url,
          by = 'commit',
        }
      end
      -- A page that is not all of them must not read as a clean head
      if (tonumber(data.total_count) or #runs) > #runs then
        return done(
          runs,
          ('only %d of %d checks were read'):format(#runs, data.total_count)
        )
      end
      done(runs)
    end)
  end
end

--- GitLab: the jobs of the newest pipeline of the head commit
---@param s DyReviewSession
---@return DyReviewCiSource
local function gitlab(s)
  return function(done)
    local project = 'projects/' .. forge.encode(s.remote.slug)
    local list = ('%s/pipelines?sha=%s&per_page=1'):format(
      project,
      forge.encode(s.pull.head_sha)
    )
    forge.api(s.remote, list, function(data, err)
      if type(data) ~= 'table' then return done(nil, err or 'no answer') end
      local last = data[1]
      if type(last) ~= 'table' or not last.id then return done({}) end
      local jobs = ('%s/pipelines/%d/jobs?per_page=100'):format(
        project,
        last.id
      )
      forge.api(s.remote, jobs, function(rows, e)
        if type(rows) ~= 'table' then return done(nil, e or 'no jobs') end
        local runs = {}
        for _, row in ipairs(rows) do
          runs[#runs + 1] = {
            provider = 'gitlab',
            name = tostring(row.name),
            state = bucket(row.status),
            url = row.web_url or last.web_url,
            by = 'commit',
          }
        end
        if #rows >= 100 then
          return done(runs, 'more than 100 jobs: not all were read')
        end
        done(runs)
      end)
    end)
  end
end

--- Whether Azure build `build` ran the pull request's head commit
---@param build table
---@param sha string
---@return boolean
local function builds_head(build, sha)
  return build.sourceVersion == sha
    or vim.tbl_get(build, 'triggerInfo', 'pr.sourceSha') == sha
end

--- Azure: the newest build of each pipeline on the pull request's merge ref,
--- the ones of the head commit when any is, else the newest with a mark
---@param s DyReviewSession
---@return DyReviewCiSource
local function azure(s)
  return function(done)
    forge.api(s.remote, {
      area = 'build',
      resource = 'builds',
      route = { project = s.remote.project },
      query = {
        branchName = ('refs/pull/%s/merge'):format(s.pull.id),
        queryOrder = 'queueTimeDescending',
        ['$top'] = 50,
      },
    }, function(data, err)
      local rows = type(data) == 'table' and data.value
      if type(rows) ~= 'table' then return done(nil, err or 'no builds') end
      local exact = vim.tbl_filter(
        function(b) return builds_head(b, s.pull.head_sha) end,
        rows
      )
      local by = #exact > 0 and 'commit' or 'branch'
      local runs, seen = {}, {}
      for _, build in ipairs(#exact > 0 and exact or rows) do
        local id = vim.tbl_get(build, 'definition', 'id') or build.id
        if not seen[id] then
          seen[id] = true
          runs[#runs + 1] = {
            provider = 'azure',
            name = vim.tbl_get(build, 'definition', 'name')
              or tostring(build.buildNumber or build.id),
            state = bucket(build.status, build.result),
            url = vim.tbl_get(build, '_links', 'web', 'href'),
            by = by,
          }
        end
      end
      done(runs)
    end)
  end
end

--- The runs of a pipeline of a system that knows branches: its jobs, or the
--- pipeline as one when it names none
---@param provider 'jenkins'|'argo'
---@param pipeline DyCiPipeline
---@param by 'branch'|'name'
---@return DyReviewCiRun[]
local function from_pipeline(provider, pipeline, by)
  local runs = {}
  for _, job in ipairs(pipeline.jobs or {}) do
    runs[#runs + 1] = {
      provider = provider,
      name = tostring(job.name),
      state = bucket(job.status, job.conclusion),
      url = pipeline.url,
      by = by,
    }
  end
  if #runs == 0 then
    runs[1] = {
      provider = provider,
      name = tostring(pipeline.id),
      state = bucket(pipeline.status),
      url = pipeline.url,
      by = by,
    }
  end
  return runs
end

--- Jenkins: the last build of the head branch's job, when the clone names a
--- job and a server
---@param s DyReviewSession
---@return DyReviewCiSource
local function jenkins(s)
  return function(done)
    local ci = require('tools.ci_jenkins')
    ci.target(s.worktree, s.pull.head_ref, function(target, err)
      -- A clone with no job or no server is not asking for Jenkins
      if not target then
        return done({}, (err and not err:find('^No Jenkins')) and err or nil)
      end
      ci.fetch(target, function(pipeline, e)
        if not pipeline then return done(nil, e or 'no answer') end
        done(from_pipeline('jenkins', pipeline, 'branch'))
      end)
    end)
  end
end

--- The lines of the first Argo workflow among the files the pull request
--- changes, read from its worktree; plain files only, so a link to another
--- path is not followed out of it
---@param s DyReviewSession
---@return string[]?
function M.argo_lines(s)
  local ci_kind = require('util.ci_kind')
  local tried = 0
  for _, file in ipairs(s.files) do
    if file.blob and file.path:match('%.ya?ml$') then
      local path = vim.fs.joinpath(s.worktree, file.path)
      local stat = vim.uv.fs_lstat(path)
      if stat and stat.type == 'file' then
        tried = tried + 1
        local lines = vim.fn.readfile(path, '', M.ARGO_LINES)
        if ci_kind.argo_kind(lines) then return lines end
        if tried >= M.ARGO_CANDIDATES then return nil end
      end
    end
  end
end

--- Argo: the last run of a workflow the pull request changes, in the current
--- kubectl context
---@param s DyReviewSession
---@return DyReviewCiSource
local function argo(s)
  return function(done)
    local lines = M.argo_lines(s)
    if not lines then return done({}) end
    -- The names come from the pull request, and the cluster is the
    -- reviewer's own: asked once the reviewer has trusted the author
    if not s.trusted then return done({}, nil, M.WAIT_FOR_TRUST) end
    local ci = require('tools.ci_argo')
    ci.target(s.worktree, lines, function(target, err)
      if not target then return done(nil, err or 'no workflow target') end
      ci.fetch(target, function(pipeline, e)
        if e and e:find('^No run of') then return done({}) end
        if not pipeline then return done(nil, e or 'no answer') end
        done(from_pipeline('argo', pipeline, 'name'))
      end)
    end)
  end
end

--- Every source to ask for `s`, by name
---@param s DyReviewSession
---@return { name: string, ask: DyReviewCiSource }[]
function M.sources(s)
  local forges = { github = github, gitlab = gitlab, azure = azure }
  local list = {}
  if forges[s.forge] then
    list[1] = { name = s.forge, ask = forges[s.forge](s) }
  end
  list[#list + 1] = { name = 'jenkins', ask = jenkins(s) }
  list[#list + 1] = { name = 'argo', ask = argo(s) }
  return list
end

--- Ask every source for the CI state of the pull request's head
---
--- A source that fails adds `<source>: <reason>` to `errors` and the others
--- still answer; a source that gave runs and a reason (a cut list) does both.
---@param s DyReviewSession
---@param cb fun(runs: DyReviewCiRun[], errors: string[], waiting: string[])
function M.status(s, cb)
  local sources = M.sources(s)
  local answers = {}
  system.each(sources, M.CONCURRENCY, function(source, done)
    local called = false
    local timer = vim.uv.new_timer()
    local function finish(runs, err, waiting)
      -- A late answer, after the deadline, is not heard
      if called then return end
      called = true
      if timer then
        timer:stop()
        timer:close()
      end
      answers[source.name] = { runs = runs, err = err, waiting = waiting }
      done()
    end
    if timer then
      timer:start(
        M.SOURCE_TIMEOUT,
        0,
        vim.schedule_wrap(function() finish(nil, 'timed out') end)
      )
    end
    local ok, raised = pcall(source.ask, finish)
    if not ok then finish(nil, tostring(raised)) end
  end, function()
    local runs, errors, waiting = {}, {}, {}
    for _, source in ipairs(sources) do
      local answer = answers[source.name]
      vim.list_extend(runs, answer.runs or {})
      if answer.err then
        errors[#errors + 1] = ('%s: %s'):format(source.name, answer.err)
      end
      if answer.waiting then
        waiting[#waiting + 1] = ('%s: %s'):format(source.name, answer.waiting)
      end
    end
    cb(runs, errors, waiting)
  end)
end

--- Fetch the state into the session, off the main loop, and draw the panel;
--- a fetch still on its way is not asked again
---@param s DyReviewSession
function M.load(s)
  if s.ci_loading then return end
  s.ci_loading = true
  local panel = require('tools.review.panel')
  panel.refresh(s)
  M.status(s, function(runs, errors, waiting)
    s.ci_loading = nil
    -- The review may have closed while the CLIs answered
    if require('tools.review.session').current() ~= s then return end
    s.ci = { runs = runs, errors = errors, waiting = waiting }
    panel.refresh(s)
  end)
end

--- One line of the picker for `run`
---@param run DyReviewCiRun
---@return string
function M.label(run)
  return ('%-9s %s  (%s%s)'):format(
    run.state,
    run.name,
    run.provider,
    run.by ~= 'commit' and ', by ' .. run.by or ''
  )
end

--- List the runs; the one chosen opens in the browser
---@param s DyReviewSession
function M.pick(s)
  local notify = require('util.notify').titled('Review')
  local runs = s.ci and s.ci.runs or {}
  if #runs == 0 then
    local why = s.ci and #s.ci.errors > 0 and table.concat(s.ci.errors, '; ')
      or 'no runs'
    return notify('CI: ' .. why, vim.log.levels.WARN)
  end
  vim.ui.select(runs, {
    prompt = 'CI runs',
    format_item = M.label,
  }, function(run)
    if not run then return end
    -- Only a web link: the url comes from a server's answer
    if not (run.url and run.url:match('^https?://')) then
      return notify(run.name .. ' has no link', vim.log.levels.WARN)
    end
    vim.ui.open(run.url)
  end)
end

return M
