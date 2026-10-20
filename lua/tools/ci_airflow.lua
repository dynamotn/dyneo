--- The last run of an Airflow DAG, for `tools.ci_inline` and `tools.ai.ci`
---
--- Asked of the REST API of the webserver the clone names (`dyneo.airflowUrl`)
--- or `DyNeo.pipelines.airflow_url`. Airflow 2 (`/api/v1`) takes a password,
--- which `curl` finds in `~/.netrc` for its own host. Airflow 3 (`/api/v2`)
--- takes only a JWT, which `DyNeo.pipelines.airflow_token_command` prints;
--- it is sent only to the host of `airflow_url`, never to one a clone names.
local M = {}

local forge = require('util.forge')
local http = require('util.ci_http')
local py = require('util.py_defs')

--- Task instances asked for per page, the most Airflow gives by default
M.PER_PAGE = 100

--- Pages of task instances read before giving up on a run
M.MAX_PAGES = 10

---@class DyAirflowTarget
---@field url string The webserver, no trailing slash
---@field api 'v1'|'v2'
---@field dag string
---@field token? string Airflow 3's JWT, kept for the calls of one action

--- Hand `on_done` the server, API and token to ask about `dag` with, for the
--- clone in `dir`
---@param dir string
---@param dag string
---@param on_done fun(target: DyAirflowTarget?, err: string?)
function M.target(dir, dag, on_done)
  local settings = DyNeo.pipelines
  http.server(dir, 'airflowUrl', settings.airflow_url, function(url, err)
    if not url then return on_done(nil, err) end
    if settings.airflow_api == 'v1' then
      return on_done({ url = url, api = 'v1', dag = dag })
    end
    if not settings.airflow_token_command then
      return on_done(
        nil,
        'Airflow 3 takes a token: set DyNeo.pipelines.airflow_token_command'
      )
    end
    http.token(
      settings.airflow_token_command,
      settings.airflow_url,
      url,
      function(token, e)
        if not token then return on_done(nil, e) end
        on_done({ url = url, api = 'v2', dag = dag, token = token })
      end
    )
  end)
end

--- The URL of `path` of the API of `target`
---@param target DyAirflowTarget
---@param path string
---@return string
local function api_url(target, path)
  return ('%s/api/%s%s'):format(target.url, target.api, path)
end

--- The headers `target` is asked with
---@param target DyAirflowTarget
---@return string[]?
local function headers(target)
  return target.token and { 'Authorization: Bearer ' .. target.token } or nil
end

--- GET `path` of the API of `target`, as JSON
---@param target DyAirflowTarget
---@param path string
---@param on_done fun(data: table?, err: string?)
local function get(target, path, on_done)
  http.json({ url = api_url(target, path), headers = headers(target) }, on_done)
end

--- The page of a run in the webserver
---@param target DyAirflowTarget
---@param run_id string
---@return string
function M.run_url(target, run_id)
  local dag = forge.encode(target.dag)
  if target.api == 'v1' then
    return ('%s/dags/%s/grid?dag_run_id=%s'):format(
      target.url,
      dag,
      forge.encode(run_id)
    )
  end
  return ('%s/dags/%s/runs/%s'):format(target.url, dag, forge.encode(run_id))
end

--- The last run of `target`'s DAG, with its task instances as jobs: a mapped
--- task's instances named `task[0]`, `task[1]`
---@param target DyAirflowTarget
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(target, on_done)
  local dag = forge.encode(target.dag)
  -- Airflow 3 dropped `execution_date` for `run_after`
  local order = target.api == 'v2' and '-run_after' or '-execution_date'
  get(
    target,
    ('/dags/%s/dagRuns?order_by=%s&limit=1'):format(dag, order),
    function(data, err)
      if not data then
        if err and err:find('404', 1, true) then
          return on_done(
            nil,
            ('No DAG %s on %s'):format(target.dag, target.url)
          )
        end
        return on_done(nil, err)
      end
      local run = type(data.dag_runs) == 'table' and data.dag_runs[1]
      if type(run) ~= 'table' or type(run.dag_run_id) ~= 'string' then
        return on_done(nil, 'No run of ' .. target.dag)
      end
      local pipeline = {
        id = run.dag_run_id,
        status = run.state,
        url = M.run_url(target, run.dag_run_id),
        jobs = {},
      }
      local path = ('/dags/%s/dagRuns/%s/taskInstances'):format(
        dag,
        forge.encode(run.dag_run_id)
      )
      local function page(index)
        get(
          target,
          ('%s?limit=%d&offset=%d'):format(path, M.PER_PAGE, index * M.PER_PAGE),
          function(tis, e)
            if not tis then return on_done(nil, e) end
            local rows = type(tis.task_instances) == 'table'
                and tis.task_instances
              or {}
            for _, ti in ipairs(rows) do
              if type(ti) == 'table' and type(ti.task_id) == 'string' then
                local mapped = type(ti.map_index) == 'number'
                  and ti.map_index >= 0
                table.insert(pipeline.jobs, {
                  id = ti.task_id,
                  name = mapped and ('%s[%d]'):format(ti.task_id, ti.map_index)
                    or ti.task_id,
                  status = type(ti.state) == 'string' and ti.state or 'none',
                  try = type(ti.try_number) == 'number' and ti.try_number or 1,
                  map_index = mapped and ti.map_index or -1,
                })
              end
            end
            local total = tonumber(tis.total_entries) or 0
            if #rows < M.PER_PAGE or #pipeline.jobs >= total then
              return on_done(pipeline)
            end
            if index + 1 >= M.MAX_PAGES then
              return on_done(
                nil,
                ('More than %d tasks: not all of them could be read'):format(
                  #pipeline.jobs
                )
              )
            end
            page(index + 1)
          end
        )
      end
      page(0)
    end
  )
end

--- The text of the lines of an Airflow 3 log as `application/x-ndjson`
--- gives them, each `{"content": ...}`: a string, a structured message
--- (`event`), or a list of either. The first may be cut short, and is
--- dropped.
---@param raw string
---@param skipped boolean Whether the start was left out
---@return string
function M.ndjson_text(raw, skipped)
  local out = {}
  local function add(item)
    if type(item) == 'string' then
      table.insert(out, item)
    elseif type(item) == 'table' then
      if type(item.event) == 'string' then
        table.insert(out, item.event)
      elseif vim.islist(item) then
        for _, one in ipairs(item) do
          add(one)
        end
      end
    end
  end
  local first = true
  for line in raw:gmatch('[^\n]+') do
    if not (first and skipped) then
      local ok, data = pcall(vim.json.decode, line)
      if ok and type(data) == 'table' then add(data.content) end
    end
    first = false
  end
  return table.concat(out, '\n')
end

--- Hand `on_done` the end of the log of `job`, a task instance of run
--- `pipeline`, at most `max_bytes` of it
---@param target DyAirflowTarget
---@param pipeline DyCiPipeline
---@param job DyCiJob
---@param max_bytes integer
---@param on_done fun(text: string?, cut: boolean, err: string?, skipped: boolean)
function M.log(target, pipeline, job, max_bytes, on_done)
  local url = api_url(
    target,
    ('/dags/%s/dagRuns/%s/taskInstances/%s/logs/%d?full_content=true&map_index=%d'):format(
      forge.encode(target.dag),
      forge.encode(tostring(pipeline.id)),
      forge.encode(tostring(job.id)),
      job.try or 1,
      job.map_index or -1
    )
  )
  if target.api == 'v1' then
    return http.tail(
      url,
      max_bytes,
      on_done,
      { '--header', 'Accept: text/plain' },
      headers(target)
    )
  end
  -- Airflow 3 answers no plain text: one JSON object a line
  http.tail(url, max_bytes, function(raw, cut, err, skipped)
    if not raw then return on_done(nil, cut, err, skipped) end
    on_done(M.ndjson_text(raw, skipped), cut, nil, skipped)
  end, { '--header', 'Accept: application/x-ndjson' }, headers(target))
end

--- The DAGs `lines` define, in the order they appear: `DAG("id")`,
--- `DAG(dag_id="id")` and `@dag`, whose id is its function's name unless it
--- says otherwise
---@param lines string[]
---@return { id: string, line: integer }[]
function M.dags(lines)
  local dags = {}
  for _, call in ipairs(py.calls(lines, { 'DAG' })) do
    local id = py.kwarg(call.args, 'dag_id') or py.first_string(call.args)
    if id then table.insert(dags, { id = id, line = call.line }) end
  end
  for _, def in ipairs(py.decorated(lines, { 'dag' })) do
    table.insert(
      dags,
      { id = py.kwarg(def.args, 'dag_id') or def.func, line = def.line }
    )
  end
  table.sort(dags, function(a, b) return a.line < b.line end)
  return dags
end

--- Where each task of `lines` is defined: an operator's `task_id="..."`,
--- a `@task` function (`@task.bash` and the like too), and a task group,
--- whose tasks Airflow names `group.task`
---@param lines string[]
---@return table<string, integer>
function M.job_lines(lines)
  local jobs = {}
  for number, line in ipairs(lines) do
    if not line:match('^%s*#') then
      for _, id in line:gmatch('%f[%w_]task_id%s*=%s*[rbuf]?(["\'])(.-)%1') do
        jobs[id] = jobs[id] or number
      end
    end
  end
  for _, def in ipairs(py.decorated(lines, { 'task' })) do
    local id = py.kwarg(def.args, 'task_id') or def.func
    jobs[id] = jobs[id] or def.line
  end
  for _, def in ipairs(py.decorated(lines, { 'task_group' })) do
    local id = py.kwarg(def.args, 'group_id') or def.func
    jobs[id] = jobs[id] or def.line
  end
  return jobs
end

return M
