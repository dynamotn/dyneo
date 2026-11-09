local h = require('helpers')

--- A CallHierarchyItem named `name`, defined on `line` of `uri`
local function item(name, line, detail, uri)
  local range = {
    start = { line = line, character = 0 },
    ['end'] = { line = line, character = 1 },
  }
  return {
    name = name,
    kind = vim.lsp.protocol.SymbolKind.Function,
    detail = detail,
    uri = uri or 'file:///p/main.go',
    range = range,
    selectionRange = range,
  }
end

describe('tools.callgraph', function()
  local callgraph, restores, notes

  before_each(function()
    h.unload('tools.callgraph')
    callgraph = require('tools.callgraph')
    restores, notes = {}, {}
    table.insert(
      restores,
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
    )
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  --- A fake server whose functions call as `calls` says: name -> callees
  local function server(calls, opts)
    opts = opts or {}
    local by_name = {}
    local line = 0
    for name in vim.spairs(calls) do
      by_name[name] = item(name, line, 'pkg.' .. name)
      line = line + 1
    end
    local client = {
      name = 'gopls',
      offset_encoding = 'utf-16',
      requests = {},
    }
    function client:supports_method(method)
      return opts.supports == nil or opts.supports[method] == true
    end
    function client:request(method, params, handler)
      table.insert(self.requests, method)
      if method == 'textDocument/prepareCallHierarchy' then
        handler(nil, opts.root and { by_name[opts.root] } or {})
      elseif method == 'callHierarchy/outgoingCalls' then
        local out = {}
        for _, name in ipairs(calls[params.item.name] or {}) do
          table.insert(out, { to = by_name[name], fromRanges = {} })
        end
        handler(nil, out)
      elseif method == 'callHierarchy/incomingCalls' then
        local into = {}
        for caller, callees in vim.spairs(calls) do
          if vim.tbl_contains(callees, params.item.name) then
            table.insert(into, { from = by_name[caller], fromRanges = {} })
          end
        end
        handler(nil, into)
      end
      return true, #self.requests
    end
    table.insert(
      restores,
      h.stub(vim.lsp, 'get_clients', function() return { client } end)
    )
    return client
  end

  local function graph_text()
    assert.is_true(
      vim.wait(2000, function() return vim.bo.filetype == 'markdown' end)
    )
    return table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
  end

  it('keys a node by where it is defined and escapes labels', function()
    local graph = callgraph.new()
    local a = callgraph.add(graph, item('Get<T>', 1, 'say "hi" # x'))
    assert.equals(a, callgraph.add(graph, item('Get<T>', 1)))
    local b = callgraph.add(graph, item('Get<T>', 1, nil, 'file:///other.go'))
    assert.are_not.equal(a, b)
    callgraph.link(graph, a, b)
    callgraph.link(graph, a, b)
    assert.same({
      'flowchart LR',
      '  n1["Get#lt;T#gt;<br/>say #quot;hi#quot; #35; x"]',
      '  n2["Get#lt;T#gt;"]',
      '  n1 --> n2',
      '  style n1 stroke-width:3px',
    }, callgraph.mermaid(graph))
  end)

  it('stops adding at MAX_NODES and marks the graph cut', function()
    callgraph.MAX_NODES = 2
    local graph = callgraph.new()
    callgraph.add(graph, item('a', 0))
    callgraph.add(graph, item('b', 1))
    assert.is_nil(callgraph.add(graph, item('c', 2)))
    assert.is_true(graph.cut)
    assert.equals(1, callgraph.add(graph, item('a', 0)))
  end)

  it('draws callers and callees to the depth, cycles once', function()
    vim.api.nvim_set_current_buf(h.buffer({ name = '/p/main.go' }))
    server({
      main = { 'run' },
      run = { 'step', 'run' },
      step = { 'leaf' },
      leaf = { 'deeper' },
      deeper = {},
    }, { root = 'run' })
    callgraph.open()
    local text = graph_text()
    assert.matches('```mermaid\nflowchart LR\n', text)
    assert.matches('n1%["run<br/>pkg.run"%]', text)
    -- main calls run; run calls step and itself; step calls leaf (depth 2)
    local _, self_loops = text:gsub('n1 %-%-> n1', '')
    assert.equals(1, self_loops)
    assert.matches('%-%-> n1', text)
    assert.matches('step', text)
    assert.matches('leaf', text)
    assert.is_nil(text:find('deeper', 1, true))
  end)

  it('follows one direction and a depth given as a count', function()
    vim.api.nvim_set_current_buf(h.buffer({ name = '/p/main.go' }))
    local client = server({
      main = { 'run' },
      run = { 'step' },
      step = { 'leaf' },
      leaf = {},
    }, { root = 'run' })
    callgraph.command({ count = 1, fargs = { 'outgoing' } })
    local text = graph_text()
    assert.matches('step', text)
    assert.is_nil(text:find('main', 1, true))
    assert.is_nil(text:find('leaf', 1, true))
    assert.is_false(
      vim.tbl_contains(client.requests, 'callHierarchy/incomingCalls')
    )
  end)

  it('says when the graph was cut', function()
    callgraph.MAX_NODES = 2
    vim.api.nvim_set_current_buf(h.buffer({ name = '/p/main.go' }))
    server({ run = { 'a', 'b', 'c' }, a = {}, b = {}, c = {} }, {
      root = 'run',
    })
    callgraph.open({ direction = 'outgoing' })
    graph_text()
    assert.matches('Cut at 2 functions', notes[1])
  end)

  it('draws what came when the server is too slow', function()
    callgraph.TIMEOUT = 20
    vim.api.nvim_set_current_buf(h.buffer({ name = '/p/main.go' }))
    local client = server({ run = {} }, { root = 'run' })
    local request = client.request
    function client:request(method, params, handler)
      if method:match('^callHierarchy/') then return true, 0 end
      return request(self, method, params, handler)
    end
    callgraph.open()
    assert.matches('n1%["run', graph_text())
    assert.matches('took over 20 ms', notes[1])
  end)

  it('says so without a server that knows the call hierarchy', function()
    vim.api.nvim_set_current_buf(h.buffer({ name = '/p/main.go' }))
    server({}, { supports = {} })
    callgraph.open()
    assert.matches('No language server', notes[1])
  end)

  it('says so without a function under the cursor', function()
    vim.api.nvim_set_current_buf(h.buffer({ name = '/p/main.go' }))
    server({})
    callgraph.open()
    assert.equals('No function under the cursor', notes[1])
  end)

  it('refuses a direction it does not know', function()
    callgraph.command({ count = 0, fargs = { 'sideways' } })
    assert.matches('Not a direction: sideways', notes[1])
  end)
end)
