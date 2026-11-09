--- A Mermaid call graph of the function under the cursor
---
--- The function comes from `textDocument/prepareCallHierarchy`, asked of
--- every language server of the buffer that has it; the first to name one
--- is asked its callers (`callHierarchy/incomingCalls`) and callees
--- (`callHierarchy/outgoingCalls`), and theirs, to a depth. Each function is
--- one node, keyed by where it is defined, so a recursion or a cycle is drawn
--- once. The graph opens as a Mermaid block in a Markdown scratch buffer,
--- where `<localleader>d` (`:DyDiagram`) draws it, as the class diagram does.
local M = {}

local notify = require('util.notify').titled('Call graph')

--- Levels of callers and callees followed, unless a count says otherwise
M.DEPTH = 2
--- Functions drawn, at most; past it the graph is cut and says so
M.MAX_NODES = 60
--- Milliseconds the server has for all of it; what came by then is drawn
M.TIMEOUT = 5000
M.DIRECTIONS = { 'both', 'incoming', 'outgoing' }

local PREPARE = 'textDocument/prepareCallHierarchy'
local CALLS = {
  incoming = 'callHierarchy/incomingCalls',
  outgoing = 'callHierarchy/outgoingCalls',
}

---@class DyCallGraph
---@field nodes lsp.CallHierarchyItem[] The root first; a node's id is its index
---@field ids table<string, integer> Node id by `M.key`
---@field edges integer[][] `{ caller, callee }` ids
---@field linked table<string, true>
---@field cut boolean A node was left out for `M.MAX_NODES`
---@field error? string The first error a server answered

--- Where `item` is defined: two answers about one function are one node
---@param item lsp.CallHierarchyItem
---@return string
function M.key(item)
  local start = (item.selectionRange or item.range).start
  return ('%s:%d:%d'):format(item.uri, start.line, start.character)
end

---@return DyCallGraph
function M.new()
  return { nodes = {}, ids = {}, edges = {}, linked = {}, cut = false }
end

--- The id of `item` in `graph`, added when new; nil once the graph is full
---@param graph DyCallGraph
---@param item lsp.CallHierarchyItem
---@return integer?
function M.add(graph, item)
  local key = M.key(item)
  if graph.ids[key] then return graph.ids[key] end
  if #graph.nodes >= M.MAX_NODES then
    graph.cut = true
    return nil
  end
  table.insert(graph.nodes, item)
  graph.ids[key] = #graph.nodes
  return #graph.nodes
end

---@param graph DyCallGraph
---@param caller integer
---@param callee integer
function M.link(graph, caller, callee)
  local key = caller .. '>' .. callee
  if graph.linked[key] then return end
  graph.linked[key] = true
  table.insert(graph.edges, { caller, callee })
end

--- `text` safe inside a quoted Mermaid label, on one line
---@param text string
---@return string
local function escape(text)
  return (
    text:gsub('%s+', ' '):gsub('[#"<>]', {
      ['#'] = '#35;',
      ['"'] = '#quot;',
      ['<'] = '#lt;',
      ['>'] = '#gt;',
    })
  )
end

--- The lines of a Mermaid flowchart, callers left of their callees
---@param graph DyCallGraph
---@return string[]
function M.mermaid(graph)
  local lines = { 'flowchart LR' }
  for id, item in ipairs(graph.nodes) do
    local text = escape(item.name)
    local detail = vim.trim(item.detail or '')
    if detail ~= '' then text = text .. '<br/>' .. escape(detail) end
    table.insert(lines, ('  n%d["%s"]'):format(id, text))
  end
  for _, edge in ipairs(graph.edges) do
    table.insert(lines, ('  n%d --> n%d'):format(edge[1], edge[2]))
  end
  if #graph.nodes > 0 then
    table.insert(lines, '  style n1 stroke-width:3px')
  end
  return lines
end

--- Follow the calls of `root` with `client`, then `done` with the graph
---@param client vim.lsp.Client
---@param bufnr integer
---@param root lsp.CallHierarchyItem
---@param direction 'both'|'incoming'|'outgoing'
---@param depth integer
---@param done fun(graph: DyCallGraph, timed_out: boolean)
function M.walk(client, bufnr, root, direction, depth, done)
  local graph = M.new()
  M.add(graph, root)
  -- Held at one while the first requests go out, so a server that answers
  -- at once does not finish the walk before the second direction starts
  local pending, finished = 1, false
  local expanded = { incoming = {}, outgoing = {} }
  local function finish(timed_out)
    if finished then return end
    finished = true
    done(graph, timed_out)
  end
  local function settle()
    pending = pending - 1
    if pending == 0 then finish(false) end
  end
  local function expand(item, id, dir, level)
    if level >= depth or expanded[dir][id] then return end
    if not client:supports_method(CALLS[dir], bufnr) then return end
    expanded[dir][id] = true
    pending = pending + 1
    local ok = client:request(CALLS[dir], { item = item }, function(err, calls)
      if finished then return end
      if err then graph.error = graph.error or err.message end
      for _, call in ipairs(not err and calls or {}) do
        local other = dir == 'incoming' and call.from or call.to
        local other_id = other and M.add(graph, other)
        if other_id then
          if dir == 'incoming' then
            M.link(graph, other_id, id)
          else
            M.link(graph, id, other_id)
          end
          expand(other, other_id, dir, level + 1)
        end
      end
      settle()
    end, bufnr)
    if not ok then settle() end
  end
  local dirs = direction == 'both' and { 'incoming', 'outgoing' }
    or { direction }
  for _, dir in ipairs(dirs) do
    expand(root, 1, dir, 0)
  end
  settle()
  if not finished then vim.defer_fn(function() finish(true) end, M.TIMEOUT) end
end

--- Open the graph beside the buffer, saying what it lacks
---@param graph DyCallGraph
---@param timed_out boolean
local function show(graph, timed_out)
  local lines = { '```mermaid' }
  vim.list_extend(lines, M.mermaid(graph))
  table.insert(lines, '```')
  require('util.scratch').open(lines, {
    name = 'Call graph: ' .. graph.nodes[1].name,
    filetype = 'markdown',
    split = 'vertical',
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
  local notes = {}
  if graph.cut then
    table.insert(notes, ('Cut at %d functions'):format(M.MAX_NODES))
  end
  if timed_out then
    table.insert(
      notes,
      ('The server took over %d ms; drawn with what came'):format(M.TIMEOUT)
    )
  end
  if graph.error then table.insert(notes, graph.error) end
  if #notes > 0 then notify(table.concat(notes, '. '), vim.log.levels.WARN) end
end

---@class DyCallGraphOpts
---@field direction? 'both'|'incoming'|'outgoing' `both` unless given
---@field depth? integer `M.DEPTH` unless given

--- The call graph of the function under the cursor
---@param opts? DyCallGraphOpts
function M.open(opts)
  opts = opts or {}
  local direction = opts.direction or 'both'
  if not vim.tbl_contains(M.DIRECTIONS, direction) then
    return notify(
      ('Not a direction: %s (%s)'):format(
        direction,
        table.concat(M.DIRECTIONS, ', ')
      ),
      vim.log.levels.ERROR
    )
  end
  local depth = opts.depth or M.DEPTH
  local bufnr = vim.api.nvim_get_current_buf()
  local win = vim.api.nvim_get_current_win()
  local clients = vim.tbl_filter(
    function(c) return c:supports_method(PREPARE, bufnr) end,
    vim.lsp.get_clients({ bufnr = bufnr, method = PREPARE })
  )
  if #clients == 0 then
    return notify(
      'No language server of this buffer knows the call hierarchy',
      vim.log.levels.WARN
    )
  end
  local settled, replies, last_err = false, 0, nil
  local function answered(client, err, items)
    replies = replies + 1
    if settled then return end
    local item = not err and items and items[1]
    if item then
      settled = true
      return M.walk(client, bufnr, item, direction, depth, show)
    end
    last_err = err or last_err
    if replies == #clients then
      settled = true
      if last_err then return notify(last_err.message, vim.log.levels.ERROR) end
      notify('No function under the cursor')
    end
  end
  for _, client in ipairs(clients) do
    local params =
      vim.lsp.util.make_position_params(win, client.offset_encoding)
    local ok = client:request(
      PREPARE,
      params,
      function(err, items) answered(client, err, items) end,
      bufnr
    )
    if not ok then answered(client, nil, nil) end
  end
  if not settled then
    vim.defer_fn(function()
      if settled then return end
      settled = true
      notify(
        ('No language server answered within %d ms'):format(M.TIMEOUT),
        vim.log.levels.WARN
      )
    end, M.TIMEOUT)
  end
end

--- `:[count]DyCallGraph [direction] [depth]`
---@param args vim.api.keyset.create_user_command.command_args
function M.command(args)
  local opts = { depth = args.count > 0 and args.count or nil }
  for _, arg in ipairs(args.fargs) do
    local n = tonumber(arg)
    if n and n >= 1 and n == math.floor(n) then
      opts.depth = n
    else
      opts.direction = arg
    end
  end
  M.open(opts)
end

return M
