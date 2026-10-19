--- The last run of an Argo workflow, for `tools.ci_inline` and `tools.ai.ci`
---
--- Asked of the current kubectl context, as `:DyKube` asks it, and pinned to
--- that context for every later call: switching it in between does not send
--- a log request to another cluster. A `WorkflowTemplate`, a
--- `ClusterWorkflowTemplate` and a `CronWorkflow` find their runs by the
--- label Argo puts on them; a `Workflow` by its name, or the runs its
--- `generateName` starts.
local M = {}

local system = require('util.system')

--- Seconds kubectl waits on the API server
M.REQUEST_TIMEOUT = 20

--- Bytes of JSON read from the cluster
M.MAX_BYTES = 8 * 1024 * 1024

--- Lines from the end of a step's log that are read
M.LOG_LINES = 5000

--- The label Argo puts on a run, by the kind it was started from
M.LABELS = {
  WorkflowTemplate = 'workflows.argoproj.io/workflow-template',
  ClusterWorkflowTemplate = 'workflows.argoproj.io/cluster-workflow-template',
  CronWorkflow = 'workflows.argoproj.io/cron-workflow',
}

--- The container of a step that runs its work
M.CONTAINER = 'main'

---@class DyArgoTarget
---@field kind string `Workflow`, `WorkflowTemplate`, ...
---@field name? string
---@field generate_name? string
---@field namespace string
---@field context string The kubectl context every call is made in

--- A YAML scalar without its comment and quotes
---@param value string
---@return string
local function scalar(value)
  value = vim.trim((value:gsub('%s+#.*$', '')))
  return (value:gsub('^(["\'])(.*)%1$', '%2'))
end

--- The kind, name, `generateName` and namespace the first document of
--- `lines` declares
---@param lines string[]
---@return { kind?: string, name?: string, generate_name?: string, namespace?: string }
function M.read(lines)
  local found, in_metadata = {}, false
  for _, line in ipairs(lines) do
    if line:match('^%-%-%-') and found.kind then break end
    local kind = line:match('^kind:(.*)$')
    if kind then found.kind = scalar(kind) end
    if line:match('^%S') then
      in_metadata = line:match('^metadata%s*:%s*$') ~= nil
    elseif in_metadata then
      local key, value = line:match('^  ([%a]+)%s*:(.*)$')
      if key == 'name' then found.name = scalar(value) end
      if key == 'generateName' then found.generate_name = scalar(value) end
      if key == 'namespace' then found.namespace = scalar(value) end
    end
  end
  for key, value in pairs(found) do
    if value == '' then found[key] = nil end
  end
  return found
end

--- Hand `on_done` the runs `lines` defines are looked for by, in the current
--- context, or why there are none
---@param dir string
---@param lines string[]
---@param on_done fun(target: DyArgoTarget?, err: string?)
function M.target(dir, lines, on_done)
  local found = M.read(lines)
  if not found.kind then return on_done(nil, 'No kind in this file') end
  if not (found.name or found.generate_name) then
    return on_done(nil, 'This workflow has no name or generateName')
  end
  if found.kind ~= 'Workflow' and not found.name then
    return on_done(nil, 'This ' .. found.kind .. ' has no name')
  end
  require('tools.kube').current(dir, function(context, namespace)
    if not context then return on_done(nil, 'No current kubectl context') end
    on_done({
      kind = found.kind,
      name = found.name,
      generate_name = found.generate_name,
      namespace = found.namespace or namespace,
      context = context,
    })
  end)
end

--- `kubectl` in the context and the namespace of `target`
---@param target DyArgoTarget
---@param args string[]
---@return string[]
function M.kubectl(target, args)
  return vim.list_extend({
    'kubectl',
    '--context',
    target.context,
    '--namespace',
    target.namespace,
    '--request-timeout',
    M.REQUEST_TIMEOUT .. 's',
  }, args)
end

--- Run `args` of kubectl for `target` and decode its JSON
---@param target DyArgoTarget
---@param args string[]
---@param on_done fun(data: table?, err: string?)
local function get_json(target, args, on_done)
  system.run(M.kubectl(target, args), {
    timeout = (M.REQUEST_TIMEOUT + 5) * 1000,
    max_bytes = M.MAX_BYTES,
    -- An exec credential plugin may ask for a login
    detach = true,
  }, function(result)
    if result.code ~= 0 then
      return on_done(nil, system.failure(result, 'kubectl'))
    end
    if result.cut then
      return on_done(nil, 'kubectl answered with more than can be read')
    end
    local ok, data = pcall(
      vim.json.decode,
      result.stdout or '',
      { luanil = { object = true, array = true } }
    )
    if not ok or type(data) ~= 'table' then
      return on_done(nil, 'kubectl answered with something not JSON')
    end
    on_done(data)
  end)
end

--- The name of the newest run of `target`, from the names and creation
--- times of the runs listed
---@param target DyArgoTarget
---@param items table[] `.items` of a workflow list
---@return string?
function M.newest(target, items)
  local best, when
  for _, item in ipairs(items) do
    local name = vim.tbl_get(item, 'metadata', 'name')
    local created = vim.tbl_get(item, 'metadata', 'creationTimestamp') or ''
    local ours = type(name) == 'string'
      and (
        M.LABELS[target.kind] ~= nil
        or name == target.name
        or (
          target.generate_name ~= nil
          and name:sub(1, #target.generate_name) == target.generate_name
        )
      )
    -- RFC 3339 times in UTC sort as text
    if ours and (not when or created > when) then
      best, when = name, created
    end
  end
  return best
end

--- The pipeline a workflow object comes down to: its nodes that run a step
---@param workflow table
---@return DyCiPipeline
function M.pipeline(workflow)
  local jobs = {}
  local nodes = vim.tbl_get(workflow, 'status', 'nodes')
  for id, node in pairs(type(nodes) == 'table' and nodes or {}) do
    if
      type(node) == 'table'
      and (
        node.type == 'Pod'
        or node.type == 'Skipped'
        or node.type == 'Suspend'
      )
    then
      table.insert(jobs, {
        id = node.id or id,
        name = node.displayName or node.name or id,
        template = node.templateName,
        status = node.phase,
      })
    end
  end
  -- `pairs` order is not stable: the marks are, the order of a pick too
  table.sort(jobs, function(a, b) return a.name < b.name end)
  return {
    id = vim.tbl_get(workflow, 'metadata', 'name'),
    status = vim.tbl_get(workflow, 'status', 'phase') or 'Pending',
    jobs = jobs,
  }
end

--- The last run of `target`, with the steps it ran as jobs
---@param target DyArgoTarget
---@param on_done fun(pipeline: DyCiPipeline?, err: string?)
function M.fetch(target, on_done)
  local function show(name)
    get_json(
      target,
      { 'get', 'workflows.argoproj.io', name, '--output', 'json' },
      function(workflow, err)
        if not workflow then return on_done(nil, err) end
        on_done(M.pipeline(workflow))
      end
    )
  end
  local label = M.LABELS[target.kind]
  if target.kind == 'Workflow' and target.name then return show(target.name) end
  -- Only the names and times, a line each: a run's whole status may be large
  local args = {
    'get',
    'workflows.argoproj.io',
    '--output',
    [[jsonpath={range .items[*]}{.metadata.name}{"\t"}{.metadata.creationTimestamp}{"\n"}{end}]],
  }
  if label then
    vim.list_extend(args, { '--selector', label .. '=' .. target.name })
  end
  system.run(M.kubectl(target, args), {
    timeout = (M.REQUEST_TIMEOUT + 5) * 1000,
    max_bytes = M.MAX_BYTES,
    detach = true,
  }, function(result)
    if result.code ~= 0 then
      return on_done(nil, system.failure(result, 'kubectl'))
    end
    if result.cut then
      return on_done(nil, 'kubectl listed more runs than can be read')
    end
    local items = {}
    for name, created in (result.stdout or ''):gmatch('([^\t\n]+)\t([^\n]*)') do
      table.insert(
        items,
        { metadata = { name = name, creationTimestamp = created } }
      )
    end
    local name = M.newest(target, items)
    if not name then
      return on_done(
        nil,
        ('No run of %s in %s/%s'):format(
          target.name or target.generate_name,
          target.context,
          target.namespace
        )
      )
    end
    show(name)
  end)
end

--- Lists that hold the steps of a workflow, by the key above their items
local STEP_LISTS = { templates = true, tasks = true, steps = true }

--- Where each template, DAG task and step of a workflow is defined: the
--- items `- name:` of `templates:`, `tasks:` and `steps:`, and not those of
--- `parameters:` or `env:`
---@param lines string[]
---@return table<string, integer>
function M.job_lines(lines)
  local jobs, keys = {}, {}
  for number, line in ipairs(lines) do
    if line:match('^%s*#') or not line:match('%S') then goto continue end
    if line:match('^%-%-%-') then keys = {} end
    local indent = #line:match('^(%s*)')
    local dash = line:match('^%s*%-')
    if dash then
      -- What was under the previous item is no parent of this one
      for at in pairs(keys) do
        if at > indent then keys[at] = nil end
      end
      local double, name = line:match('^%s*%-%s+(%-?)%s*name%s*:(.*)$')
      if name then
        local parent, best = nil, -1
        for at, key in pairs(keys) do
          if at <= indent and at > best then
            parent, best = key, at
          end
        end
        -- `- - name:` is a step of a group running in parallel
        if double == '-' then parent = 'steps' end
        name = scalar(name)
        if STEP_LISTS[parent] and name ~= '' and not jobs[name] then
          jobs[name] = number
        end
      end
    else
      local key = line:match('^%s*([%w_]+)%s*:')
      if key then
        for at in pairs(keys) do
          if at >= indent then keys[at] = nil end
        end
        keys[indent] = key
      end
    end
    ::continue::
  end
  return jobs
end

--- Hand `on_done` the end of the log of `job`, a step of run `pipeline`,
--- from the pod that ran it
---@param target DyArgoTarget
---@param pipeline DyCiPipeline
---@param job DyCiJob
---@param on_done fun(text: string?, cut: boolean, err: string?, skipped: boolean)
function M.log(target, pipeline, job, on_done)
  get_json(target, {
    'get',
    'pods',
    '--selector',
    'workflows.argoproj.io/workflow=' .. pipeline.id,
    '--output',
    'json',
  }, function(pods, err)
    if not pods then return on_done(nil, false, err, false) end
    local pod
    for _, item in ipairs(type(pods.items) == 'table' and pods.items or {}) do
      local annotations = vim.tbl_get(item, 'metadata', 'annotations') or {}
      if annotations['workflows.argoproj.io/node-id'] == job.id then
        pod = vim.tbl_get(item, 'metadata', 'name')
      end
    end
    if not pod then
      return on_done(
        nil,
        false,
        ('The pod of %s is gone: its log is no longer in the cluster'):format(
          job.name
        ),
        false
      )
    end
    system.run(
      M.kubectl(target, {
        'logs',
        pod,
        '--container',
        M.CONTAINER,
        '--tail',
        tostring(M.LOG_LINES + 1),
      }),
      {
        timeout = (M.REQUEST_TIMEOUT + 5) * 1000,
        max_bytes = M.MAX_BYTES,
        detach = true,
      },
      function(result)
        if result.code ~= 0 then
          return on_done(nil, false, system.failure(result, 'kubectl'), false)
        end
        local text = result.stdout or ''
        -- One line more than kept says the start was left out
        local count = select(2, text:gsub('\n', ''))
        local skipped = count > M.LOG_LINES
        if skipped then text = text:gsub('^[^\n]*\n', '', 1) end
        on_done(text, result.cut, nil, skipped)
      end
    )
  end)
end

return M
