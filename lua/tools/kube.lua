--- Kubernetes from the manifest being edited
---
--- The round trip from a manifest to the cluster -- does this differ from
--- what runs, would the API server take it, what does the chart render to --
--- is a terminal away, with the file name typed again and the context to
--- remember. Here it starts from the buffer: a plain manifest goes to
--- `kubectl -f`, a `kustomization.yaml` to `kubectl -k`, and a file of a Helm
--- chart is rendered with `helm template` first, the values file being edited
--- taken as its values.
---
--- Applying asks first, naming the context it would apply to. What a render
--- or a diff shows can hold the data of a Secret, so those buffers are kept
--- from every AI integration.
local M = {}

--- Milliseconds a `kubectl` or `helm` command may take
M.TIMEOUT = 2 * 60 * 1000

---@class DyKubeTarget
---@field kind 'manifest'|'kustomize'|'helm'
---@field file string The file the buffer holds
---@field dir string Where the commands run
---@field chart? string The chart directory, for `helm`
---@field values? string The values file being edited, for `helm`
---@field template? string The template being edited, relative to the chart

--- What a file is, as far as getting it to a cluster goes
---@param file string
---@return DyKubeTarget
function M.target(file)
  local dir = vim.fs.dirname(file)
  local name = vim.fs.basename(file)
  if name:match('^[Kk]ustomization%.ya?ml$') then
    return { kind = 'kustomize', file = file, dir = dir }
  end
  local chart = vim.fs.root(file, 'Chart.yaml')
  if chart then
    local target = { kind = 'helm', file = file, dir = chart, chart = chart }
    local relative = file:sub(#chart + 2)
    if name:match('^values.*%.ya?ml$') then
      target.values = file
    elseif relative:match('^templates/') then
      target.template = relative
    end
    return target
  end
  return { kind = 'manifest', file = file, dir = dir }
end

--- The `helm template` that renders `target`
---@param target DyKubeTarget
---@return string[]
function M.render_command(target)
  local command = {
    'helm',
    'template',
    vim.fs.basename(target.chart),
    target.chart,
  }
  if target.values then
    vim.list_extend(command, { '--values', target.values })
  end
  if target.template then
    vim.list_extend(command, { '--show-only', target.template })
  end
  return command
end

--- `kubectl <verb>` for `target`, reading the render from stdin for a chart
---@param verb string[] `{ 'diff' }`, `{ 'apply', '--dry-run=server' }`, ...
---@param target DyKubeTarget
---@return string[]
function M.kubectl_command(verb, target)
  local command = vim.list_extend({ 'kubectl' }, verb)
  if target.kind == 'kustomize' then
    return vim.list_extend(command, { '-k', target.dir })
  elseif target.kind == 'helm' then
    return vim.list_extend(command, { '-f', '-' })
  end
  return vim.list_extend(command, { '-f', target.file })
end

local notify = require('util.notify').titled('Kubernetes')

--- Run `command` in `dir`, and hand its result over on the main loop
---@param command string[]
---@param dir string
---@param stdin? string
---@param on_done fun(result: vim.SystemCompleted)
local function run(command, dir, stdin, on_done)
  require('util.system').run(
    command,
    { cwd = dir, stdin = stdin, timeout = M.TIMEOUT },
    function(result)
      if result.missing then
        return notify(result.stderr, vim.log.levels.ERROR)
      end
      -- A child stopped at the output cap exits 0: what it printed is only
      -- the start of a render, a diff or a list, never the whole of it. One
      -- stopped at the deadline printed nothing a caller can read either.
      if result.cut or result.timed_out then
        local failure = require('util.system').failure(result, command[1])
        return notify(failure, vim.log.levels.ERROR)
      end
      on_done(result)
    end
  )
end

--- Hand `on_rendered` what `target` sends to the cluster: the rendered
--- chart for `helm`, nothing to send on stdin otherwise
---@param target DyKubeTarget
---@param on_rendered fun(stdin: string?)
local function rendered(target, on_rendered)
  if target.kind ~= 'helm' then return on_rendered(nil) end
  run(M.render_command(target), target.dir, nil, function(result)
    if result.code ~= 0 then
      return notify(
        'helm template failed:\n' .. vim.trim(result.stderr or ''),
        vim.log.levels.ERROR
      )
    end
    on_rendered(result.stdout)
  end)
end

--- Show `text` in a tab of its own, kept from every AI integration
---@param text string
---@param filetype string
---@param name string
local function show(text, filetype, name)
  -- Named, so a second diff of the same file opens beside the first one
  require('util.scratch').open(vim.split(text, '\n', { trimempty = true }), {
    name = name,
    filetype = filetype,
    sensitive = 'Kubernetes output, which can hold Secret data',
  })
end

--- The target of the current buffer, or nil when it holds no file
---
--- kubectl and helm read the file on disk: a buffer with changes not yet
--- written would be judged, or applied, by what it no longer says.
---@return DyKubeTarget?
local function current()
  local file = vim.api.nvim_buf_get_name(0)
  if file == '' then
    notify('This buffer holds no file', vim.log.levels.WARN)
    return nil
  end
  if vim.bo.modified then
    notify(
      'Write the buffer first: kubectl reads the file on disk',
      vim.log.levels.WARN
    )
    return nil
  end
  local target = M.target(file)
  -- kustomize and helm read every file of their directory, not only this one
  if target.kind ~= 'manifest' then
    local root = require('util.root')
    local dir = root.realpath(target.dir) or target.dir
    for _, buf in ipairs(vim.fn.getbufinfo({ bufmodified = 1 })) do
      if
        buf.name ~= ''
        and root.contains(dir, root.realpath(buf.name) or buf.name)
      then
        notify(
          ('Write %s first: %s reads it from disk'):format(
            vim.fn.fnamemodify(buf.name, ':~:.'),
            target.kind
          ),
          vim.log.levels.WARN
        )
        return nil
      end
    end
  end
  return target
end

--- What would change in the cluster
function M.diff()
  local target = current()
  if not target then return end
  rendered(target, function(stdin)
    run(
      M.kubectl_command({ 'diff' }, target),
      target.dir,
      stdin,
      function(result)
        -- `kubectl diff` exits 1 when there are differences, above it on error
        if result.code == 0 then
          return notify('No differences with the cluster')
        end
        if result.code ~= 1 then
          return notify(
            'kubectl diff failed:\n' .. vim.trim(result.stderr or ''),
            vim.log.levels.ERROR
          )
        end
        show(
          result.stdout or '',
          'diff',
          'kube://diff/' .. vim.fs.basename(target.file)
        )
      end
    )
  end)
end

--- Whether the API server would take it, without changing anything
function M.dry_run()
  local target = current()
  if not target then return end
  rendered(target, function(stdin)
    run(
      M.kubectl_command({ 'apply', '--dry-run=server' }, target),
      target.dir,
      stdin,
      function(result)
        local out =
          vim.trim((result.stdout or '') .. '\n' .. (result.stderr or ''))
        notify(
          out,
          result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        )
      end
    )
  end)
end

--- Hand `on_done` the current context and the namespace it puts an object
--- without one in, read off the main loop; no context when there is none
---
--- Only those two fields are asked for: the rest of the kubeconfig holds
--- credentials, and none of it is needed here.
---@param dir string
---@param on_done fun(context: string?, namespace: string)
function M.current(dir, on_done)
  run(
    {
      'kubectl',
      'config',
      'view',
      '--minify',
      '-o',
      'jsonpath={.current-context}{"\\t"}{.contexts[0].context.namespace}',
    },
    dir,
    nil,
    function(result)
      local context, namespace = (result.code == 0 and result.stdout or ''):match(
        '^([^\t]*)\t?(.*)$'
      )
      context, namespace = vim.trim(context or ''), vim.trim(namespace or '')
      on_done(
        context ~= '' and context or nil,
        namespace ~= '' and namespace or 'default'
      )
    end
  )
end

--- Apply it, once told to, to the context named -- and to that one only,
--- however the current context changes in the meantime
function M.apply()
  local target = current()
  if not target then return end
  if target.kind == 'helm' then
    -- `kubectl apply` of a render creates the objects outside of Helm, under
    -- a release name guessed from the directory: the next `helm upgrade`
    -- then fails on their ownership
    return notify(
      'A chart is applied with `helm upgrade`, not kubectl',
      vim.log.levels.WARN
    )
  end
  M.current(target.dir, function(context, namespace)
    if not context then
      return notify('No current kubectl context', vim.log.levels.ERROR)
    end
    local answer = vim.fn.confirm(
      ('Apply %s to context %s, namespace %s by default?'):format(
        vim.fs.basename(target.file),
        context,
        namespace
      ),
      '&Apply\n&Cancel',
      2
    )
    if answer ~= 1 then return end
    M.apply_to(target, context)
  end)
end

--- Apply `target` to `context`
---@param target DyKubeTarget
---@param context string
function M.apply_to(target, context)
  rendered(target, function(stdin)
    run(
      M.kubectl_command({ '--context=' .. context, 'apply' }, target),
      target.dir,
      stdin,
      function(result)
        local out =
          vim.trim((result.stdout or '') .. '\n' .. (result.stderr or ''))
        notify(
          out,
          result.code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR
        )
      end
    )
  end)
end

--- What the chart or the kustomization renders to
function M.render()
  local target = current()
  if not target then return end
  local command = target.kind == 'helm' and M.render_command(target)
    or target.kind == 'kustomize' and { 'kubectl', 'kustomize', target.dir }
  if not command then
    return notify('A plain manifest renders to itself', vim.log.levels.WARN)
  end
  run(command, target.dir, nil, function(result)
    if result.code ~= 0 then
      return notify(
        command[1] .. ' failed:\n' .. vim.trim(result.stderr or ''),
        vim.log.levels.ERROR
      )
    end
    show(
      result.stdout or '',
      'yaml',
      'kube://render/' .. vim.fs.basename(target.file)
    )
  end)
end

--- Pick among the lines `list` prints, then run `apply` with the one picked
---@param list string[]
---@param prompt string
---@param apply fun(choice: string): string[]
---@param done string What to say once it is done, `%s` the choice
local function pick(list, prompt, apply, done)
  run(list, vim.uv.cwd() --[[@as string]], nil, function(result)
    if result.code ~= 0 then
      return notify(vim.trim(result.stderr or ''), vim.log.levels.ERROR)
    end
    local choices = vim.split(result.stdout or '', '\n', { trimempty = true })
    choices = vim.tbl_map(
      function(c) return (c:gsub('^namespace/', '')) end,
      choices
    )
    vim.ui.select(choices, { prompt = prompt }, function(choice)
      if not choice then return end
      run(apply(choice), vim.uv.cwd() --[[@as string]], nil, function(set)
        if set.code ~= 0 then
          return notify(vim.trim(set.stderr or ''), vim.log.levels.ERROR)
        end
        notify(done:format(choice))
      end)
    end)
  end)
end

--- Switch the current context
function M.context()
  pick(
    { 'kubectl', 'config', 'get-contexts', '-o', 'name' },
    'Context',
    function(choice) return { 'kubectl', 'config', 'use-context', choice } end,
    'Context is now %s'
  )
end

--- Switch the namespace of the current context
function M.namespace()
  pick(
    { 'kubectl', 'get', 'namespaces', '-o', 'name' },
    'Namespace',
    function(choice)
      return {
        'kubectl',
        'config',
        'set-context',
        '--current',
        '--namespace=' .. choice,
      }
    end,
    'Namespace is now %s'
  )
end

--- Milliseconds `kubectl explain` may take: it only reads the API schema
M.EXPLAIN_TIMEOUT = 30 * 1000

--- The key a YAML line sets and the column it starts at, past any `- ` of a
--- sequence item; nil for a comment, a scalar item or a line of a block
---@param line string
---@return string? key
---@return integer column
---@return boolean parent Whether the value is on the lines below
local function key_of(line)
  local indent, rest = line:match('^(%s*)(.*)$')
  local column = #indent
  while rest:match('^%-%s') or rest == '-' do
    local dash, after = rest:match('^(%-%s*)(.*)$')
    column = column + #dash
    rest = after
  end
  if rest:match('^#') then return nil, column, false end
  local key, value = rest:match('^([%w_%.%-/]+)%s*:%s*(.*)$')
  if not key then
    key, value = rest:match('^["\']([^"\']+)["\']%s*:%s*(.*)$')
  end
  if not key then return nil, column, false end
  value = value:gsub('%s+#.*$', '')
  return key, column, value == ''
end

--- The field of the YAML object at `row`: the keys from the top of its
--- document down to the one the line sets, or the one it sits under, with
--- the `apiVersion` and `kind` of that document
---
--- Read off the indentation rather than a parser, so it holds without the
--- YAML parser installed and on a template of a chart, which is no YAML.
---@param lines string[]
---@param row integer 1-based
---@return string[] path
---@return { api_version?: string, kind?: string } object
function M.field_at(lines, row)
  local first, last = 1, #lines
  for i = row, 1, -1 do
    if lines[i]:match('^%-%-%-') then
      first = i + 1
      break
    end
  end
  for i = row + 1, #lines do
    if lines[i]:match('^%-%-%-') then
      last = i - 1
      break
    end
  end
  local object = {}
  for i = first, last do
    local api = lines[i]:match('^apiVersion:%s*["\']?([^"\'%s#]+)')
    local kind = lines[i]:match('^kind:%s*["\']?([^"\'%s#]+)')
    object.api_version = object.api_version or api
    object.kind = object.kind or kind
  end

  local path = {}
  -- A scalar item counts from past its `- `, so the key it sits under is
  -- left of it even when the sequence is not indented under that key
  local key, column = key_of(lines[row] or '')
  if key then table.insert(path, key) end
  for i = row - 1, first, -1 do
    if column == 0 then break end
    local parent, at, opens = key_of(lines[i])
    if parent and opens and at < column then
      table.insert(path, 1, parent)
      column = at
    end
  end
  return path, object
end

--- What the API server says of the field under the cursor, in a float
---
--- A key that is no field -- one of `labels`, of the `data` of a ConfigMap
--- -- is dropped, and the field it sits in explained instead.
function M.explain()
  local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local path, object = M.field_at(lines, row)
  if not object.kind then
    return notify('No `kind` in this document', vim.log.levels.WARN)
  end
  if vim.fn.executable('kubectl') ~= 1 then
    return notify('kubectl is not installed', vim.log.levels.ERROR)
  end
  local function try(depth)
    local field = table.concat(
      vim.list_extend({ object.kind:lower() }, vim.list_slice(path, 1, depth)),
      '.'
    )
    local command = { 'kubectl', 'explain', field }
    if object.api_version then
      table.insert(command, '--api-version=' .. object.api_version)
    end
    require('util.system').run(
      command,
      { timeout = M.EXPLAIN_TIMEOUT },
      function(result)
        if result.code ~= 0 then
          -- Only a field the schema lacks is worth a shallower question; a
          -- cluster out of reach would only time out once more per level
          local missing = (result.stderr or ''):find('does not exist', 1, true)
          if depth > 0 and missing and not result.timed_out then
            return try(depth - 1)
          end
          return notify(
            'kubectl explain failed:\n'
              .. require('util.system').failure(result, 'kubectl'),
            vim.log.levels.ERROR
          )
        end
        local out = vim.split(vim.trim(result.stdout or ''), '\n')
        if depth < #path then
          table.insert(
            out,
            1,
            ('`%s` is not a field of `%s`'):format(path[depth + 1], field)
          )
          table.insert(out, 2, '')
        end
        vim.lsp.util.open_floating_preview(out, 'text', {
          border = 'rounded',
          focus_id = 'dy_kube_explain',
          max_height = 30,
          max_width = 90,
        })
      end
    )
  end
  try(#path)
end

M.SUBCOMMANDS = {
  explain = M.explain,
  diff = M.diff,
  dryrun = M.dry_run,
  apply = M.apply,
  render = M.render,
  context = M.context,
  namespace = M.namespace,
}

--- `:DyKube {subcommand}`
---@param args { fargs: string[] }
function M.command(args)
  local sub = args.fargs[1] or 'diff'
  local fn = M.SUBCOMMANDS[sub]
  if not fn then
    return notify('Unknown subcommand: ' .. sub, vim.log.levels.ERROR)
  end
  fn()
end

--- Whether `bufnr` holds something a cluster would take: a manifest with an
--- `apiVersion` and a `kind`, a kustomization, or a file of a chart
---@param bufnr integer
---@return boolean
function M.is_kube(bufnr)
  local file = vim.api.nvim_buf_get_name(bufnr)
  if file == '' then return false end
  local target = M.target(file)
  if target.kind ~= 'manifest' then return true end
  return M.is_manifest(bufnr)
end

--- Whether `bufnr` holds a Kubernetes object itself, `apiVersion` and
--- `kind` at the top level -- not a chart's values or a kustomization
---@param bufnr integer
---@return boolean
function M.is_manifest(bufnr)
  if bufnr == 0 then bufnr = vim.api.nvim_get_current_buf() end
  local api, kind = false, false
  for _, line in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 200, false)) do
    api = api or line:match('^apiVersion:') ~= nil
    kind = kind or line:match('^kind:') ~= nil
    if api and kind then return true end
  end
  return false
end

--- The mappings of a buffer that holds something for a cluster
---@param bufnr integer
function M.attach(bufnr)
  if not M.is_kube(bufnr) then return end
  local function map(lhs, rhs, desc)
    vim.keymap.set('n', lhs, rhs, { buffer = bufnr, desc = desc })
  end
  local ok, wk = pcall(require, 'which-key')
  if ok then
    wk.add({ { '<localleader>k', group = 'kubernetes', buffer = bufnr } })
  end
  map('<localleader>ke', M.explain, 'Explain Field')
  map('<localleader>kd', M.diff, 'Diff With Cluster')
  map('<localleader>kv', M.dry_run, 'Validate (Server Dry Run)')
  map('<localleader>ka', M.apply, 'Apply')
  map('<localleader>kr', M.render, 'Render (Helm, Kustomize)')
  map('<localleader>kc', M.context, 'Switch Context')
  map('<localleader>kn', M.namespace, 'Switch Namespace')
end

return M
