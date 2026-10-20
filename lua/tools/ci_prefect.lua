--- The last run of a Prefect flow, for `tools.ci_inline` and `tools.ai.ci`
---
--- Asked through Prefect's own client, in the Python that runs `prefect`:
--- it reads the API URL and key from the active profile or `PREFECT_*`, and
--- sends the key only to that URL, so none is read here. It runs outside the
--- repository, so a `.env` or `prefect.toml` of the tree cannot point it, key
--- and all, at another server; and never starts a server of its own.
local M = {}

local py = require('util.py_defs')
local system = require('util.system')

--- Milliseconds the client may take
M.TIMEOUT = 60 * 1000

--- Runs of a flow looked through for the last one that ran
M.RUNS = 10

--- Task runs read of a flow run
M.TASK_RUNS = 500

--- Log lines read, from the end
M.LOG_LINES = 5000

--- The client's side, given `runs <flow>` or `logs <flow run> <task run>
--- <limit>`: it prints JSON, or the log's lines
M.SCRIPT = [==[
import json, sys
from prefect.client.orchestration import get_client
from prefect.client.schemas.filters import (
    FlowFilter, FlowFilterName, FlowRunFilter, FlowRunFilterId,
    LogFilter, LogFilterFlowRunId, LogFilterTaskRunId,
)
from prefect.client.schemas.sorting import FlowRunSort, LogSort

def state(run):
    kind = run.state_type
    return kind.value if kind is not None else None

with get_client(sync_client=True) as client:
    if sys.argv[1] == "runs":
        runs = client.read_flow_runs(
            flow_filter=FlowFilter(name=FlowFilterName(any_=[sys.argv[2]])),
            sort=FlowRunSort.START_TIME_DESC,
            limit=int(sys.argv[3]),
        )
        # A run only scheduled has not run yet
        runs = [r for r in runs if state(r) != "SCHEDULED"]
        if not runs:
            print(json.dumps({"run": None}))
            sys.exit(0)
        run = runs[0]
        tasks = client.read_task_runs(
            flow_run_filter=FlowRunFilter(id=FlowRunFilterId(any_=[run.id])),
            limit=int(sys.argv[4]),
        )
        url = None
        try:
            from prefect.utilities.urls import url_for
            url = url_for(run)
        except Exception:
            pass
        print(json.dumps({
            "run": {"id": str(run.id), "name": run.name, "state": state(run),
                    "url": url},
            "tasks": [{"id": str(t.id), "name": t.name, "state": state(t)}
                      for t in tasks],
        }))
    else:
        log_filter = LogFilter(flow_run_id=LogFilterFlowRunId(any_=[sys.argv[2]]))
        if sys.argv[3]:
            log_filter.task_run_id = LogFilterTaskRunId(any_=[sys.argv[3]])
        logs = client.read_logs(
            log_filter=log_filter,
            sort=LogSort.TIMESTAMP_DESC,
            limit=int(sys.argv[4]),
        )
        for log in reversed(logs):
            print(log.message)
]==]

---@class DyPrefectTarget
---@field flow string The flow's name, as its runs carry it
---@field python string The Python that runs `prefect`

--- The flows `lines` define: `@flow`, named after its function with `_`
--- turned to `-` as Prefect names it, unless it says `name=`
---@param lines string[]
---@return { id: string, line: integer }[]
function M.flows(lines)
  local flows = {}
  for _, def in ipairs(py.decorated(lines, { 'flow' })) do
    table.insert(flows, {
      id = py.kwarg(def.args, 'name') or (def.func:gsub('_', '-')),
      line = def.line,
    })
  end
  return flows
end

--- Where each task and flow of `lines` is defined, by the name its runs
--- carry: a task its function's, unless it says `name=`
---@param lines string[]
---@return table<string, integer>
function M.job_lines(lines)
  local jobs = {}
  for _, def in ipairs(py.decorated(lines, { 'task' })) do
    local id = py.kwarg(def.args, 'name') or def.func
    jobs[id] = jobs[id] or def.line
  end
  for _, flow in ipairs(M.flows(lines)) do
    jobs[flow.id] = jobs[flow.id] or flow.line
  end
  return jobs
end

--- The Python that runs `prefect`: the project's `.venv`, else the one
--- beside the `prefect` on `$PATH`, wherever that links to
---@param root? string The project
---@return string? python
---@return string? err
function M.python(root)
  local candidates = {}
  if root then
    table.insert(candidates, vim.fs.joinpath(root, '.venv', 'bin', 'prefect'))
  end
  local found = vim.fn.exepath('prefect')
  if found ~= '' then table.insert(candidates, found) end
  for _, prefect in ipairs(candidates) do
    if vim.fn.executable(prefect) == 1 then
      local real = vim.uv.fs_realpath(prefect) or prefect
      for _, name in ipairs({ 'python', 'python3' }) do
        local python = vim.fs.joinpath(vim.fs.dirname(real), name)
        if vim.fn.executable(python) == 1 then return python end
      end
    end
  end
  return nil, 'prefect is not installed, here or in the project'
end

--- Hand `on_done` how to ask about `flow` for the project at `root`
---@param root? string
---@param flow string
---@param on_done fun(target: DyPrefectTarget?, err: string?)
function M.target(root, flow, on_done)
  local python, err = M.python(root)
  if not python then return on_done(nil, err) end
  on_done({ flow = flow, python = python })
end

--- Run the client's side of `target` with `args`
---@param target DyPrefectTarget
---@param args string[]
---@param on_done fun(result: DyRunResult)
local function client(target, args, on_done)
  system.run(vim.list_extend({ target.python, '-I', '-c', M.SCRIPT }, args), {
    timeout = M.TIMEOUT,
    -- Away from the tree, whose settings files the client would read
    cwd = vim.fn.stdpath('cache'),
    env = { PREFECT_SERVER_ALLOW_EPHEMERAL_MODE = 'false' },
    detach = true,
  }, on_done)
end

--- The last run of `target`'s flow, with its task runs as jobs and the
--- flow itself as one more, on its `@flow` line
---@param target DyPrefectTarget
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(target, on_done)
  client(
    target,
    { 'runs', target.flow, tostring(M.RUNS), tostring(M.TASK_RUNS) },
    function(result)
      if result.code ~= 0 then
        local stderr = vim.trim(result.stderr or '')
        -- The traceback's last line says what went wrong
        local last = stderr:match('([^\n]+)$')
        return on_done(nil, last or system.failure(result, 'prefect'))
      end
      local ok, data = pcall(
        vim.json.decode,
        result.stdout or '',
        { luanil = { object = true, array = true } }
      )
      if not ok or type(data) ~= 'table' then
        return on_done(nil, 'Prefect answered with something not JSON')
      end
      local run = data.run
      if type(run) ~= 'table' then
        return on_done(nil, 'No run of flow ' .. target.flow)
      end
      local jobs = {
        { id = '', name = target.flow, status = run.state },
      }
      for _, task in ipairs(type(data.tasks) == 'table' and data.tasks or {}) do
        if type(task) == 'table' and type(task.name) == 'string' then
          table.insert(
            jobs,
            { id = task.id, name = task.name, status = task.state }
          )
        end
      end
      on_done({
        id = run.name or run.id,
        run_id = run.id,
        status = run.state or 'PENDING',
        url = type(run.url) == 'string' and run.url or nil,
        jobs = jobs,
      })
    end
  )
end

--- Hand `on_done` the end of the log of `job` of run `pipeline`: a task
--- run's, or the whole flow run's for the flow itself
---@param target DyPrefectTarget
---@param pipeline DyCiPipeline
---@param job DyCiJob
---@param on_done fun(text: string?, cut: boolean, err: string?, skipped: boolean)
function M.log(target, pipeline, job, on_done)
  client(target, {
    'logs',
    tostring(pipeline.run_id),
    tostring(job.id or ''),
    tostring(M.LOG_LINES),
  }, function(result)
    if result.code ~= 0 then
      local last = vim.trim(result.stderr or ''):match('([^\n]+)$')
      return on_done(
        nil,
        false,
        last or system.failure(result, 'prefect'),
        false
      )
    end
    local text = result.stdout or ''
    local count = select(2, text:gsub('\n', ''))
    on_done(text, result.cut, nil, count >= M.LOG_LINES)
  end)
end

return M
