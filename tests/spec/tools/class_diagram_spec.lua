local h = require('helpers')

local K = vim.lsp.protocol.SymbolKind

--- A DocumentSymbol named `name` of `kind`, on `line`
local function symbol(name, kind, line, children, detail)
  local range = {
    start = { line = line, character = 0 },
    ['end'] = { line = line, character = 1 },
  }
  return {
    name = name,
    kind = kind,
    detail = detail,
    range = range,
    selectionRange = range,
    children = children,
  }
end

describe('tools.class_diagram', function()
  local diagram, restores

  before_each(function()
    h.unload('tools.class_diagram')
    diagram = require('tools.class_diagram')
    restores = {}
  end)
  after_each(function()
    for i = #restores, 1, -1 do
      restores[i]()
    end
    vim.cmd('silent! %bwipeout!')
  end)

  local symbols = {
    symbol('Shape', K.Interface, 0, {
      symbol('area()', K.Method, 1, nil, ' : double'),
    }),
    symbol('Circle', K.Class, 3, {
      symbol('radius', K.Field, 4, nil, ' : double'),
      symbol('Circle(double)', K.Constructor, 5),
      symbol('area()', K.Method, 6, nil, ' : double'),
      symbol('Inner', K.Class, 7, {}),
    }),
    symbol('Color', K.Enum, 9, { symbol('RED', K.EnumMember, 10) }),
    symbol('helper', K.Function, 12),
  }

  it('reads classes, their fields and methods, nested ones too', function()
    local classes = diagram.collect(symbols)
    assert.same(
      { 'Shape', 'Circle', 'Inner', 'Color' },
      vim.tbl_map(function(c) return c.name end, classes)
    )
    assert.equals('interface', classes[1].kind)
    assert.same(
      { 'radius : double', 'Circle(double)', 'area() : double' },
      vim.tbl_map(function(m) return m.label end, classes[2].members)
    )
    assert.is_false(classes[2].members[1].method)
    assert.is_true(classes[2].members[3].method)
    assert.equals('enumeration', classes[4].kind)
  end)

  it('writes Mermaid, generics and all', function()
    local lines = diagram.mermaid({
      {
        name = 'Box<T>',
        kind = 'class',
        members = {
          { label = 'get() : T', method = true },
          { label = 'items : List<T>', method = false },
        },
      },
      { name = 'Shape', kind = 'interface', members = {} },
    }, {
      { from = 'Box<T>', to = 'Shape', interface = true },
      { from = 'Box<T>', to = 'Base', interface = false },
    })
    assert.same({
      'classDiagram',
      '  class Box~T~ {',
      '    +get() : T',
      '    items : List~T~',
      '  }',
      '  class Shape {',
      '    <<interface>>',
      '  }',
      '  Shape <|.. Box~T~',
      '  Base <|-- Box~T~',
    }, lines)
  end)

  it('asks the server for supertypes and opens the diagram', function()
    local bufnr = h.buffer({ name = '/p/Circle.java', filetype = 'java' })
    vim.api.nvim_set_current_buf(bufnr)
    local client = {
      name = 'jdtls',
      offset_encoding = 'utf-16',
      server_capabilities = {
        documentSymbolProvider = true,
        typeHierarchyProvider = true,
      },
    }
    function client:supports_method(method)
      return method == 'textDocument/documentSymbol'
        or method == 'textDocument/prepareTypeHierarchy'
    end
    function client:request(method, params, handler)
      local result
      if method == 'textDocument/documentSymbol' then
        result = symbols
      elseif method == 'textDocument/prepareTypeHierarchy' then
        result = { { name = 'at' .. params.position.line, kind = K.Class } }
      elseif method == 'typeHierarchy/supertypes' then
        result = params.item.name == 'at3'
            and { { name = 'Shape', kind = K.Interface } }
          or {}
      end
      handler(nil, result)
      return true, 1
    end
    table.insert(
      restores,
      h.stub(vim.lsp, 'get_clients', function() return { client } end)
    )
    diagram.open()
    assert.is_true(
      vim.wait(2000, function() return vim.bo.filetype == 'markdown' end)
    )
    local text = table.concat(vim.api.nvim_buf_get_lines(0, 0, -1, false), '\n')
    assert.matches('```mermaid\nclassDiagram\n', text)
    assert.matches('Shape <|%.%. Circle', text)
    assert.matches('```$', text)
  end)

  it('says so without a server that lists symbols', function()
    local notes = {}
    table.insert(
      restores,
      h.stub(vim, 'notify', function(msg) table.insert(notes, msg) end)
    )
    table.insert(
      restores,
      h.stub(vim.lsp, 'get_clients', function() return {} end)
    )
    diagram.open()
    assert.matches('No language server', notes[1])
  end)
end)
