--- A Mermaid class diagram of the buffer, from its language server
---
--- The classes, interfaces and enums of the buffer come from
--- `textDocument/documentSymbol`, with their fields and methods; what each
--- extends or implements from `typeHierarchy/supertypes`, where the server
--- has it. The diagram opens as a Mermaid block in a Markdown scratch buffer,
--- where `<localleader>d` (`:DyDiagram`) draws it.
local M = {}

local notify = require('util.notify').titled('Class diagram')
local K = vim.lsp.protocol.SymbolKind

--- Classes asked about their supertypes, at most
M.LIMIT = 50
--- Milliseconds the server has for all of it; what came by then is drawn
M.TIMEOUT = 5000

local CLASSES = {
  [K.Class] = 'class',
  [K.Struct] = 'class',
  [K.Interface] = 'interface',
  [K.Enum] = 'enumeration',
}
local METHODS = {
  [K.Method] = true,
  [K.Constructor] = true,
  [K.Function] = true,
}
local FIELDS = {
  [K.Field] = true,
  [K.Property] = true,
  [K.Constant] = true,
  [K.EnumMember] = true,
}

---@class DyClassMember
---@field label string
---@field method boolean

---@class DyClass
---@field name string
---@field kind 'class'|'interface'|'enumeration'
---@field members DyClassMember[]
---@field position? lsp.Position Where the server is asked about it

---@class DyClassEdge
---@field from string The subtype
---@field to string The supertype
---@field interface boolean Implemented rather than extended

--- A member's label: its name, and the type the server details
---@param sym table
---@return string
local function label(sym)
  local detail = vim.trim(sym.detail or '')
  return detail == '' and sym.name or (sym.name .. ' ' .. detail)
end

--- The classes of a `documentSymbol` answer, nested ones after their outer
---@param symbols table[] DocumentSymbol[] or SymbolInformation[]
---@return DyClass[]
function M.collect(symbols)
  local classes = {}
  local by_name = {}
  local function walk(list, owner)
    for _, sym in ipairs(list or {}) do
      local kind = CLASSES[sym.kind]
      if kind then
        local range = sym.selectionRange
          or vim.tbl_get(sym, 'location', 'range')
        local class = {
          name = sym.name,
          kind = kind,
          members = {},
          position = range and range.start,
        }
        table.insert(classes, class)
        by_name[sym.name] = class
        walk(sym.children, class)
      else
        -- A flat answer names the owner instead of nesting the member
        local into = owner or by_name[sym.containerName or '']
        if into and (METHODS[sym.kind] or FIELDS[sym.kind]) then
          table.insert(
            into.members,
            { label = label(sym), method = METHODS[sym.kind] == true }
          )
        end
      end
    end
  end
  walk(symbols, nil)
  return classes
end

--- `text` with generics as Mermaid writes them: `List<T>` -> `List~T~`
---@param text string
---@return string
local function generics(text) return (text:gsub('[<>]', '~')) end

--- The lines of a Mermaid class diagram
---@param classes DyClass[]
---@param edges DyClassEdge[]
---@return string[]
function M.mermaid(classes, edges)
  local lines = { 'classDiagram' }
  for _, class in ipairs(classes) do
    table.insert(lines, ('  class %s {'):format(generics(class.name)))
    if class.kind ~= 'class' then
      table.insert(lines, ('    <<%s>>'):format(class.kind))
    end
    for _, member in ipairs(class.members) do
      table.insert(
        lines,
        ('    %s%s'):format(member.method and '+' or '', generics(member.label))
      )
    end
    table.insert(lines, '  }')
  end
  for _, edge in ipairs(edges) do
    table.insert(
      lines,
      ('  %s %s %s'):format(
        generics(edge.to),
        edge.interface and '<|..' or '<|--',
        generics(edge.from)
      )
    )
  end
  return lines
end

--- Open the diagram of `classes` and `edges` beside the buffer
---@param classes DyClass[]
---@param edges DyClassEdge[]
---@param name string
local function show(classes, edges, name)
  local lines = { '```mermaid' }
  vim.list_extend(lines, M.mermaid(classes, edges))
  table.insert(lines, '```')
  require('util.scratch').open(lines, {
    name = 'Class diagram: ' .. vim.fn.fnamemodify(name, ':t'),
    filetype = 'markdown',
    split = 'vertical',
  })
  vim.api.nvim_win_set_cursor(0, { 2, 0 })
end

--- The class diagram of the current buffer
function M.open()
  local bufnr = vim.api.nvim_get_current_buf()
  local client
  for _, c in
    ipairs(vim.lsp.get_clients({
      bufnr = bufnr,
      method = 'textDocument/documentSymbol',
    }))
  do
    if c:supports_method('textDocument/documentSymbol', bufnr) then
      client = c
      break
    end
  end
  if not client then
    return notify(
      'No language server lists the symbols of this buffer',
      vim.log.levels.WARN
    )
  end
  local document = vim.lsp.util.make_text_document_params(bufnr)
  client:request('textDocument/documentSymbol', {
    textDocument = document,
  }, function(err, symbols)
    if err then return notify(err.message, vim.log.levels.ERROR) end
    local classes = M.collect(symbols or {})
    if #classes == 0 then return notify('No class in this buffer') end
    local edges, pending, drawn = {}, 0, false
    local name = vim.api.nvim_buf_get_name(bufnr)
    local function draw()
      if drawn then return end
      drawn = true
      show(classes, edges, name)
    end
    local function settle()
      pending = pending - 1
      if pending == 0 then draw() end
    end
    if
      not client:supports_method('textDocument/prepareTypeHierarchy', bufnr)
    then
      return draw()
    end
    -- Held at one while the requests go out: a server that answers at once
    -- would otherwise have it drawn after the first class
    pending = 1
    for i, class in ipairs(classes) do
      if i > M.LIMIT then break end
      if class.position then
        pending = pending + 1
        client:request('textDocument/prepareTypeHierarchy', {
          textDocument = document,
          position = class.position,
        }, function(_, items)
          local item = items and items[1]
          if not item then return settle() end
          client:request(
            'typeHierarchy/supertypes',
            { item = item },
            function(_, supers)
              for _, super in ipairs(supers or {}) do
                -- The root every Java class has says nothing
                if super.name ~= 'Object' then
                  table.insert(edges, {
                    from = class.name,
                    to = super.name,
                    interface = class.kind ~= 'interface'
                      and super.kind == K.Interface,
                  })
                end
              end
              settle()
            end,
            bufnr
          )
        end, bufnr)
      end
    end
    settle()
    if not drawn then vim.defer_fn(draw, M.TIMEOUT) end
  end, bufnr)
end

return M
