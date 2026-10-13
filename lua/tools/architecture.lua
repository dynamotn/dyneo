--- A diagram of what the files of a directory build, drawn from the files
---
--- `:DyArchitecture` reads the directory of the buffer and writes the D2 of
--- what it declares, in a buffer to preview with `<leader>cp` or keep:
---
--- - Terraform: each `resource`, `data` and `module` block, and an arrow to
---   every block its body refers to. Read off the `.tf` files as text: no
---   plan, no state, no provider.
--- - Kubernetes manifests: each object, and the links the cluster makes --
---   a Service to the workloads its selector matches, an Ingress to its
---   Services, a workload to the ConfigMaps, Secrets, claims and service
---   account it mounts, a HorizontalPodAutoscaler to what it scales. One
---   named but missing is drawn dashed.
--- - docker-compose: each service, and its `depends_on`.
local M = {}

local notify = require('util.notify').titled('Architecture')

---@class DyArchNode
---@field id string
---@field label string
---@field group? string
---@field missing? boolean

---@class DyArchGraph
---@field nodes DyArchNode[]
---@field edges { from: string, to: string, label?: string }[]

--- A graph to add to, nodes and edges each once
---@return DyArchGraph, fun(node: DyArchNode), fun(from: string, to: string, label?: string)
local function builder()
  local graph, nodes, edges = { nodes = {}, edges = {} }, {}, {}
  local function node(new)
    if nodes[new.id] then return end
    nodes[new.id] = new
    table.insert(graph.nodes, new)
  end
  local function edge(from, to, label)
    local key = from .. '\0' .. to
    if from == to or edges[key] then return end
    edges[key] = true
    table.insert(graph.edges, { from = from, to = to, label = label })
  end
  return graph, node, edge
end

--- A line of HCL with its comment cut, and the same with the text of its
--- strings blanked: a `#` or `//` inside a string is no comment, and a
--- brace inside one (`"${x}"`) opens no block
---@param line string
---@return string code The line without its comment
---@return string bare The same, strings blanked, for counting braces
function M.hcl_code(line)
  local code, bare = {}, {}
  local in_string, index = false, 1
  while index <= #line do
    local char = line:sub(index, index)
    if in_string then
      table.insert(code, char)
      if char == '\\' then
        table.insert(code, line:sub(index + 1, index + 1))
        index = index + 1
      elseif char == '"' then
        in_string = false
        table.insert(bare, '"')
      end
    elseif char == '"' then
      in_string = true
      table.insert(code, char)
      table.insert(bare, '"')
    elseif char == '#' or line:sub(index, index + 1) == '//' then
      break
    else
      table.insert(code, char)
      table.insert(bare, char)
    end
    index = index + 1
  end
  return table.concat(code), table.concat(bare)
end

--- The graph of the blocks of Terraform files and their references
---@param files table<string, string[]> Lines by file name
---@return DyArchGraph
function M.terraform(files)
  local graph, node, edge = builder()
  local blocks = {}
  local names = vim.tbl_keys(files)
  table.sort(names)
  for _, name in ipairs(names) do
    local lines = files[name]
    local index = 1
    while index <= #lines do
      local kind, first, second =
        lines[index]:match('^(%a+)%s+"([^"]+)"%s*"?([^"%s{]*)"?%s*{')
      local id
      if kind == 'resource' then
        id = first .. '.' .. second
      elseif kind == 'data' then
        id = 'data.' .. first .. '.' .. second
      elseif kind == 'module' then
        id = 'module.' .. first
      end
      if id then
        -- The body: up to the brace that closes the block
        local depth, body, last = 0, {}, index
        for row = index, #lines do
          local code, bare = M.hcl_code(lines[row])
          table.insert(body, code)
          local _, opened = bare:gsub('{', '')
          local _, closed = bare:gsub('}', '')
          depth = depth + opened - closed
          last = row
          if depth <= 0 then break end
        end
        table.insert(blocks, {
          id = id,
          kind = kind,
          body = table.concat(body, '\n'),
          group = vim.fs.basename(name),
        })
        index = last + 1
      else
        index = index + 1
      end
    end
  end
  local known = {}
  for _, block in ipairs(blocks) do
    known[block.id] = true
    node({ id = block.id, label = block.id, group = block.group })
  end
  for _, block in ipairs(blocks) do
    local text = block.body:gsub('^[^\n]*', '', 1)
    for ref in text:gmatch('data%.[%w_%-]+%.[%w_%-]+') do
      if known[ref] then edge(block.id, ref) end
    end
    for name in text:gmatch('module%.([%w_%-]+)') do
      if known['module.' .. name] then edge(block.id, 'module.' .. name) end
    end
    for ref in text:gmatch('[%a][%w%-]*_[%w_%-]*%.[%w_%-]+') do
      if known[ref] then edge(block.id, ref) end
    end
  end
  return graph
end

--- The pod spec of a workload, whatever its kind
---@param doc table
---@return table?
local function pod_spec(doc)
  local spec = type(doc.spec) == 'table' and doc.spec or {}
  if doc.kind == 'Pod' then return spec end
  if doc.kind == 'CronJob' then
    return vim.tbl_get(spec, 'jobTemplate', 'spec', 'template', 'spec')
  end
  return vim.tbl_get(spec, 'template', 'spec')
end

local WORKLOADS = {
  Deployment = true,
  StatefulSet = true,
  DaemonSet = true,
  ReplicaSet = true,
  Job = true,
  CronJob = true,
  Pod = true,
}

--- The graph of a set of Kubernetes objects
---@param docs table[] Decoded manifests
---@return DyArchGraph
function M.kube(docs)
  local graph, node, edge = builder()
  local present = {}
  local objects = {}
  for _, doc in ipairs(docs) do
    local name = type(doc) == 'table' and vim.tbl_get(doc, 'metadata', 'name')
    if type(name) == 'string' and type(doc.kind) == 'string' then
      local id = doc.kind .. '/' .. name
      present[id] = true
      table.insert(objects, { id = id, doc = doc })
      node({ id = id, label = id, group = doc.kind })
    end
  end
  local function link(from, kind, name, label)
    if type(name) ~= 'string' or name == '' then return end
    local id = kind .. '/' .. name
    if not present[id] then
      node({ id = id, label = id, group = kind, missing = true })
    end
    edge(from, id, label)
  end

  for _, object in ipairs(objects) do
    local doc, id = object.doc, object.id
    local spec = type(doc.spec) == 'table' and doc.spec or {}
    if
      doc.kind == 'Service'
      and type(spec.selector) == 'table'
      and next(spec.selector)
    then
      for _, other in ipairs(objects) do
        if WORKLOADS[other.doc.kind] then
          local labels = other.doc.kind == 'Pod'
              and vim.tbl_get(other.doc, 'metadata', 'labels')
            or other.doc.kind == 'CronJob' and vim.tbl_get(
              other.doc,
              'spec',
              'jobTemplate',
              'spec',
              'template',
              'metadata',
              'labels'
            )
            or vim.tbl_get(other.doc, 'spec', 'template', 'metadata', 'labels')
          local matches = type(labels) == 'table'
          for key, value in pairs(spec.selector) do
            if not matches or labels[key] ~= value then
              matches = false
              break
            end
          end
          if matches then edge(id, other.id, 'selects') end
        end
      end
    elseif doc.kind == 'Ingress' then
      local default = vim.tbl_get(spec, 'defaultBackend', 'service', 'name')
      link(id, 'Service', default, 'routes')
      for _, rule in ipairs(type(spec.rules) == 'table' and spec.rules or {}) do
        for _, path in ipairs(vim.tbl_get(rule, 'http', 'paths') or {}) do
          local name = vim.tbl_get(path, 'backend', 'service', 'name')
            or vim.tbl_get(path, 'backend', 'serviceName')
          link(id, 'Service', name, 'routes')
        end
      end
    elseif doc.kind == 'HorizontalPodAutoscaler' then
      local target = spec.scaleTargetRef
      if type(target) == 'table' then
        link(id, target.kind or 'Deployment', target.name, 'scales')
      end
    end

    local pod = WORKLOADS[doc.kind] and pod_spec(doc)
    if type(pod) == 'table' then
      link(id, 'ServiceAccount', pod.serviceAccountName)
      local containers = vim.list_extend(
        vim.list_extend(
          {},
          type(pod.containers) == 'table' and pod.containers or {}
        ),
        type(pod.initContainers) == 'table' and pod.initContainers or {}
      )
      for _, container in ipairs(containers) do
        for _, from in
          ipairs(type(container.envFrom) == 'table' and container.envFrom or {})
        do
          link(id, 'ConfigMap', vim.tbl_get(from, 'configMapRef', 'name'))
          link(id, 'Secret', vim.tbl_get(from, 'secretRef', 'name'))
        end
        for _, env in
          ipairs(type(container.env) == 'table' and container.env or {})
        do
          link(
            id,
            'ConfigMap',
            vim.tbl_get(env, 'valueFrom', 'configMapKeyRef', 'name')
          )
          link(
            id,
            'Secret',
            vim.tbl_get(env, 'valueFrom', 'secretKeyRef', 'name')
          )
        end
      end
      for _, volume in
        ipairs(type(pod.volumes) == 'table' and pod.volumes or {})
      do
        link(id, 'ConfigMap', vim.tbl_get(volume, 'configMap', 'name'))
        link(id, 'Secret', vim.tbl_get(volume, 'secret', 'secretName'))
        link(
          id,
          'PersistentVolumeClaim',
          vim.tbl_get(volume, 'persistentVolumeClaim', 'claimName')
        )
      end
    end
  end
  return graph
end

--- The graph of the services of a compose file
---@param doc table
---@return DyArchGraph
function M.compose(doc)
  local graph, node, edge = builder()
  local services = type(doc) == 'table'
      and type(doc.services) == 'table'
      and doc.services
    or {}
  local names = vim.tbl_keys(services)
  table.sort(names)
  for _, name in ipairs(names) do
    local service = services[name]
    local image = type(service) == 'table' and service.image
    node({
      id = name,
      label = type(image) == 'string' and (name .. '\n' .. image) or name,
    })
  end
  for _, name in ipairs(names) do
    local depends = type(services[name]) == 'table'
        and services[name].depends_on
      or {}
    local targets = vim.islist(depends) and depends or vim.tbl_keys(depends)
    table.sort(targets)
    for _, target in ipairs(targets) do
      if services[target] ~= nil then edge(name, target, 'depends on') end
    end
  end
  return graph
end

--- A D2 string literal
---@param text string
---@return string
local function quote(text)
  return '"'
    .. text:gsub('\\', '\\\\'):gsub('"', '\\"'):gsub('\n', '\\n')
    .. '"'
end

--- The D2 of `graph`
---@param graph DyArchGraph
---@param title string
---@return string[]
function M.d2(graph, title)
  local lines = {
    '# ' .. title,
    '# Written by :DyArchitecture; edit freely.',
    'direction: right',
    '',
  }
  for _, item in ipairs(graph.nodes) do
    local style = item.missing and '; style.stroke-dash: 4' or ''
    local label = item.missing and (item.label .. '\n(missing)') or item.label
    table.insert(
      lines,
      ('%s: {label: %s%s}'):format(quote(item.id), quote(label), style)
    )
  end
  if #graph.edges > 0 then table.insert(lines, '') end
  for _, link in ipairs(graph.edges) do
    table.insert(
      lines,
      ('%s -> %s%s'):format(
        quote(link.from),
        quote(link.to),
        link.label and (': ' .. quote(link.label)) or ''
      )
    )
  end
  return lines
end

--- Hand `on_done` the YAML documents of `files`, decoded through `yq` one
--- file after the other, off the main loop
---@param files string[]
---@param on_done fun(docs: table[]?, err: string?, skipped: string[]?)
function M.yaml_docs(files, on_done)
  if vim.fn.executable('yq') ~= 1 then
    return on_done(nil, 'yq is needed to read YAML')
  end
  -- One file at a time: a template of a chart (`{{ }}`) or a broken file
  -- is no YAML yq reads, and must not take the others down with it
  local docs, skipped, index = {}, {}, 0
  local function next_file()
    index = index + 1
    local file = files[index]
    if not file then return on_done(docs, nil, skipped) end
    local ok_read, lines = pcall(vim.fn.readfile, file)
    local text = ok_read and table.concat(lines, '\n') or ''
    if not ok_read or text:find('{{', 1, true) then
      table.insert(skipped, vim.fs.basename(file))
      return next_file()
    end
    require('util.system').run(
      { 'yq', '-o=json', '-I=0', '.', file },
      { timeout = 30000 },
      function(result)
        -- Cut short, its documents would be read as all there is
        if result.code ~= 0 or result.cut then
          table.insert(skipped, vim.fs.basename(file))
        else
          for line in (result.stdout or ''):gmatch('[^\n]+') do
            local decoded, doc = pcall(
              vim.json.decode,
              line,
              { luanil = { object = true, array = true } }
            )
            if decoded and type(doc) == 'table' then table.insert(docs, doc) end
          end
        end
        next_file()
      end
    )
  end
  next_file()
end

--- The files of `dir` whose name matches one of `patterns`
---@param dir string
---@param patterns string[]
---@return string[]
local function files_of(dir, patterns)
  local found = {}
  for name, kind in vim.fs.dir(dir) do
    if kind == 'file' or kind == 'link' then
      for _, pattern in ipairs(patterns) do
        if name:match(pattern) then
          table.insert(found, vim.fs.joinpath(dir, name))
          break
        end
      end
    end
  end
  table.sort(found)
  return found
end

--- Hand `on_graph` the graph of the directory of the current buffer, by
--- what it holds
---@param on_graph fun(graph: DyArchGraph?, title: string?, skipped: string[]?)
function M.read(on_graph)
  local file = vim.api.nvim_buf_get_name(0)
  local dir = file ~= '' and vim.fs.dirname(file) or vim.uv.cwd() --[[@as string]]
  local ft = vim.bo.filetype
  if ft == 'terraform' or ft == 'tf' or file:match('%.tf$') then
    local files = {}
    for _, path in ipairs(files_of(dir, { '%.tf$', '%.tofu$' })) do
      -- A dangling link is listed too
      local ok, lines = pcall(vim.fn.readfile, path)
      if ok then files[path] = lines end
    end
    return on_graph(
      M.terraform(files),
      'Terraform: ' .. vim.fn.fnamemodify(dir, ':~')
    )
  end
  if ft == 'yaml.docker-compose' or vim.fs.basename(file):match('compose') then
    return M.yaml_docs({ file }, function(docs, err, skipped)
      if not docs then return on_graph(nil, err) end
      if #skipped > 0 then
        return on_graph(nil, 'yq could not read ' .. skipped[1])
      end
      on_graph(
        M.compose(docs[1] or {}),
        'Compose: ' .. vim.fn.fnamemodify(file, ':~')
      )
    end)
  end
  if ft == 'yaml' or ft:match('^yaml%.') or ft == 'helm' then
    return M.yaml_docs(
      files_of(dir, { '%.ya?ml$' }),
      function(docs, err, skipped)
        if not docs then return on_graph(nil, err) end
        docs = vim.tbl_filter(
          function(doc)
            return type(doc.kind) == 'string' and doc.apiVersion ~= nil
          end,
          docs
        )
        on_graph(
          M.kube(docs),
          'Kubernetes: ' .. vim.fn.fnamemodify(dir, ':~'),
          skipped
        )
      end
    )
  end
  on_graph(nil, 'Draws Terraform, Kubernetes manifests and compose files')
end

--- Draw the directory of the current buffer, in a new D2 buffer
function M.open()
  M.read(function(graph, title, skipped) M.draw(graph, title, skipped) end)
end

--- Open the D2 of `graph` in a new buffer, or say why there is none
---@param graph? DyArchGraph
---@param title? string
---@param skipped? string[]
function M.draw(graph, title, skipped)
  if not graph then
    return notify(title or 'Nothing to draw', vim.log.levels.WARN)
  end
  if #graph.nodes == 0 then
    return notify('Nothing declared to draw in ' .. title)
  end
  vim.cmd('botright vnew')
  local bufnr = vim.api.nvim_get_current_buf()
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, M.d2(graph, title))
  vim.bo[bufnr].filetype = 'd2'
  vim.bo[bufnr].modified = false
  notify(
    ('%d blocks, %d links'):format(#graph.nodes, #graph.edges)
      .. (
        skipped
          and #skipped > 0
          and ('; left out: ' .. table.concat(skipped, ', '))
        or ''
      )
  )
end

return M
