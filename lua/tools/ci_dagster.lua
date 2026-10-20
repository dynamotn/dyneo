--- The last run of a Dagster job, for `tools.ci_inline` and `tools.ai.ci`
---
--- Asked of the GraphQL API of the webserver the clone names
--- (`dyneo.dagsterUrl`) or `DyNeo.pipelines.dagster_url`. A Dagster+ token,
--- which `DyNeo.pipelines.dagster_token_command` prints, goes only to the
--- host of `dagster_url`, never to one a clone names.
local M = {}

local http = require('util.ci_http')
local py = require('util.py_defs')

--- The job Dagster runs assets in when no job of the file names them
M.ASSET_JOB = '__ASSET_JOB'

--- Log events read per page, and pages read before giving up
M.EVENTS = 1000
M.MAX_PAGES = 20

---@class DyDagsterTarget
---@field url string The webserver, or a Dagster+ deployment
---@field job string
---@field token? string A Dagster+ token, kept for the calls of one action

--- The jobs `lines` define: `@job` (its function's name unless it says
--- `name=`) and `define_asset_job("name")`
---@param lines string[]
---@return { id: string, line: integer }[]
function M.jobs(lines)
  local jobs = {}
  for _, def in ipairs(py.decorated(lines, { 'job' })) do
    table.insert(
      jobs,
      { id = py.kwarg(def.args, 'name') or def.func, line = def.line }
    )
  end
  for _, call in ipairs(py.calls(lines, { 'define_asset_job' })) do
    local id = py.kwarg(call.args, 'name') or py.first_string(call.args)
    if id then table.insert(jobs, { id = id, line = call.line }) end
  end
  table.sort(jobs, function(a, b) return a.line < b.line end)
  return jobs
end

--- Whether `lines` define assets
---@param lines string[]
---@return boolean
function M.has_assets(lines) return #py.decorated(lines, { 'asset' }) > 0 end

--- Where each asset and op of `lines` is defined, by the step it runs as:
--- its function's name unless it says `name=`, an asset's behind its
--- `key_prefix` joined with `__`
---@param lines string[]
---@return table<string, integer>
function M.job_lines(lines)
  local steps = {}
  for _, def in ipairs(py.decorated(lines, { 'asset', 'op' })) do
    local id = py.kwarg(def.args, 'name') or def.func
    local prefix = def.decorator == 'asset' and py.kwarg(def.args, 'key_prefix')
    if prefix then id = prefix .. '__' .. id end
    steps[id] = steps[id] or def.line
  end
  for _, job in ipairs(M.jobs(lines)) do
    steps[job.id] = steps[job.id] or job.line
  end
  return steps
end

--- Hand `on_done` the server and token to ask about `job` with, for the
--- clone in `dir`
---@param dir string
---@param job string
---@param on_done fun(target: DyDagsterTarget?, err: string?)
function M.target(dir, job, on_done)
  local settings = DyNeo.pipelines
  http.server(dir, 'dagsterUrl', settings.dagster_url, function(url, err)
    if not url then return on_done(nil, err) end
    http.token(
      settings.dagster_token_command,
      settings.dagster_url,
      url,
      function(token, e)
        if e then return on_done(nil, e) end
        on_done({ url = url, job = job, token = token })
      end
    )
  end)
end

--- Ask `query` of the GraphQL API of `target`, and hand `on_done` its data
---@param target DyDagsterTarget
---@param query string
---@param variables table
---@param on_done fun(data: table?, err: string?)
local function graphql(target, query, variables, on_done)
  http.json({
    url = target.url .. '/graphql',
    method = 'POST',
    body = { query = query, variables = variables },
    headers = target.token and { 'Dagster-Cloud-Api-Token: ' .. target.token }
      or nil,
  }, function(answer, err)
    if not answer then return on_done(nil, err) end
    local errors = answer.errors
    if type(errors) == 'table' and type(errors[1]) == 'table' then
      return on_done(nil, 'Dagster: ' .. tostring(errors[1].message))
    end
    if type(answer.data) ~= 'table' then
      return on_done(nil, 'Dagster answered with no data')
    end
    on_done(answer.data)
  end)
end

M.RUNS_QUERY = [[
query DyRuns($job: String!) {
  runsOrError(filter: { pipelineName: $job }, limit: 1) {
    __typename
    ... on Runs { results { runId status stepStats { stepKey status } } }
    ... on PythonError { message }
    ... on InvalidPipelineRunsFilterError { message }
  }
}]]

--- The last run of `target`'s job, with its steps as jobs
---@param target DyDagsterTarget
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(target, on_done)
  graphql(target, M.RUNS_QUERY, { job = target.job }, function(data, err)
    if not data then return on_done(nil, err) end
    local runs = data.runsOrError
    if type(runs) ~= 'table' then
      return on_done(nil, 'Dagster answered with no runs')
    end
    if type(runs.results) ~= 'table' then
      return on_done(
        nil,
        'Dagster: ' .. tostring(runs.message or runs.__typename)
      )
    end
    local run = runs.results[1]
    if type(run) ~= 'table' or type(run.runId) ~= 'string' then
      return on_done(nil, 'No run of job ' .. target.job)
    end
    local jobs = {}
    for _, step in
      ipairs(type(run.stepStats) == 'table' and run.stepStats or {})
    do
      if type(step) == 'table' and type(step.stepKey) == 'string' then
        table.insert(
          jobs,
          { id = step.stepKey, name = step.stepKey, status = step.status }
        )
      end
    end
    on_done({
      id = run.runId,
      status = run.status or 'QUEUED',
      url = ('%s/runs/%s'):format(target.url, run.runId),
      jobs = jobs,
    })
  end)
end

M.LOGS_QUERY = [[
query DyLogs($run: ID!, $cursor: String, $limit: Int) {
  logsForRun(runId: $run, afterCursor: $cursor, limit: $limit) {
    __typename
    ... on EventConnection {
      cursor
      hasMore
      events {
        __typename
        ... on MessageEvent { message stepKey }
        ... on ExecutionStepFailureEvent { error { message stack } }
      }
    }
    ... on RunNotFoundError { message }
    ... on PythonError { message }
  }
}]]

--- The lines of `events` about `step`: their messages, and a failure's
--- error and stack
---@param events table[]
---@param step string
---@return string[]
function M.step_lines(events, step)
  local lines = {}
  for _, event in ipairs(events) do
    if type(event) == 'table' and event.stepKey == step then
      if type(event.message) == 'string' then
        table.insert(lines, event.message)
      end
      local error = event.error
      if type(error) == 'table' then
        if type(error.message) == 'string' then
          table.insert(lines, error.message)
        end
        for _, frame in
          ipairs(type(error.stack) == 'table' and error.stack or {})
        do
          if type(frame) == 'string' then
            table.insert(lines, (frame:gsub('\n$', '')))
          end
        end
      end
    end
  end
  return lines
end

--- Hand `on_done` the end of what run `pipeline` logged about step `job`,
--- at most `max_bytes` of it
---@param target DyDagsterTarget
---@param pipeline DyCiPipeline
---@param job DyCiJob
---@param max_bytes integer
---@param on_done fun(text: string?, cut: boolean, err: string?, skipped: boolean)
function M.log(target, pipeline, job, max_bytes, on_done)
  local lines = {}
  local function page(index, cursor)
    graphql(target, M.LOGS_QUERY, {
      run = pipeline.id,
      cursor = cursor,
      limit = M.EVENTS,
    }, function(data, err)
      if not data then return on_done(nil, false, err, false) end
      local logs = data.logsForRun
      if type(logs) ~= 'table' or type(logs.events) ~= 'table' then
        return on_done(
          nil,
          false,
          'Dagster: '
            .. tostring(type(logs) == 'table' and logs.message or 'no log'),
          false
        )
      end
      vim.list_extend(lines, M.step_lines(logs.events, tostring(job.id)))
      if logs.hasMore and index + 1 < M.MAX_PAGES then
        return page(index + 1, logs.cursor)
      end
      local text = table.concat(lines, '\n')
      local skipped = #text > max_bytes
      if skipped then text = text:sub(#text - max_bytes + 1) end
      -- Pages left unread hold the end of the run
      on_done(text, logs.hasMore == true, nil, skipped)
    end)
  end
  page(0, nil)
end

return M
