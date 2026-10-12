--- Neogen configurations for the `neogen` convention each language names in
--- `config.languages`: the conventions neogen ships none of, each in the
--- documentation style of its own ecosystem, and neogen's own for the compound
--- filetypes it would not find -- it looks a configuration up by the exact
--- `filetype`, so `typescript.tsx` never reaches `typescriptreact`'s.
---
--- A configuration is only built once neogen loads, from its spec's `opts`:
--- building one requires neogen.
local M = {}

--- A template writes `$1` where neogen leaves a jump mark, so no template here
--- may hold a literal `$` of its own.

---@param node TSNode
---@return string
local function text(node) return vim.treesitter.get_node_text(node, 0) end

--- The `field` of each child of `node` of type `kind`, as text
---@param node? TSNode
---@param kind string
---@param field? string Defaults to `name`
---@return string[]
local function names(node, kind, field)
  local ret = {}
  if not node then return ret end
  for child in node:iter_children() do
    local name = child:type() == kind and child:field(field or 'name')[1]
    if name then ret[#ret + 1] = text(name) end
  end
  return ret
end

--- Drop the empty lists of `data`: neogen counts an empty key as a result,
--- which keeps the `no_results` rows of a template from rendering
---@param data table<string, string[]>
---@return table<string, string[]>
local function found(data)
  for key, value in pairs(data) do
    if #value == 0 then data[key] = nil end
  end
  return data
end

---@param node TSNode
---@param types string[]
---@return TSNode?
local function of_type(node, types)
  if vim.list_contains(types, node:type()) then return node end
end

--- Whether `node` sits right inside a node of one of `types`
---@param node TSNode
---@param types string[]
---@return boolean
local function inside(node, types)
  local parent = node:parent()
  return parent ~= nil and vim.list_contains(types, parent:type())
end

---@class DyNeogenSpec
---@field name string The annotation convention
---@field parent table<string, string[]> Node types to document, by kind
---@field lines table The neogen template
---@field extract? fun(node: TSNode): table<string, string[]>
---@field pick? fun(node: TSNode, types: string[]): TSNode? Turns a node on
--- the way up from the cursor into the one to document, or rejects it
---@field position? fun(node: TSNode, kind: string): integer, integer

--- A neogen configuration from a `DyNeogenSpec`
---@param spec DyNeogenSpec
---@return table
local function build(spec)
  local data = {}
  for kind, types in pairs(spec.parent) do
    data[kind] = {
      [table.concat(types, '|')] = {
        ['0'] = { extract = spec.extract or function() return {} end },
      },
    }
  end
  local pick = spec.pick or of_type
  return {
    parent = spec.parent,
    data = data,
    locator = function(info, types)
      local node = info.current or info.root
      while node do
        local target = pick(node, types)
        if target then return target end
        node = node:parent()
      end
    end,
    template = {
      annotation_convention = spec.name,
      use_default_comment = false,
      position = spec.position,
      [spec.name] = spec.lines,
    },
  }
end

local function dart()
  return build({
    name = 'dartdoc',
    parent = {
      func = { 'function_signature', 'method_signature', 'declaration' },
      class = {
        'class_definition',
        'mixin_declaration',
        'enum_declaration',
        'extension_declaration',
      },
    },
    -- A body follows its signature as a sibling instead of sitting inside it,
    -- and a method's signature is wrapped in a `method_signature`
    pick = function(node, types)
      if node:type() == 'function_body' then
        node = node:prev_named_sibling()
      end
      if node and inside(node, { 'method_signature' }) then
        node = node:parent()
      end
      return node and of_type(node, types)
    end,
    -- Above the metadata of the declaration, `@override` and the like
    position = function(node)
      local prev = node:prev_named_sibling()
      while prev and prev:type() == 'annotation' do
        node, prev = prev, prev:prev_named_sibling()
      end
      return node:range()
    end,
    lines = { { nil, '/// $1', { no_results = true } } },
  })
end

--- What a definition of Elixir documents, by the macro defining it
local ELIXIR_DEFS = {
  def = 'public',
  defmacro = 'public',
  defguard = 'public',
  defdelegate = 'public',
  defp = 'private',
  defmacrop = 'private',
  defguardp = 'private',
  defmodule = 'module',
  defprotocol = 'module',
}

---@param node TSNode
---@return string?
local function elixir_kind(node)
  if node:type() ~= 'call' then return end
  local target = node:field('target')[1]
  return target and target:type() == 'identifier' and ELIXIR_DEFS[text(target)]
    or nil
end

local function elixir()
  return build({
    name = 'exdoc',
    -- A definition is a `call` like any other, told apart by its target
    parent = { func = { 'call' } },
    pick = function(node) return elixir_kind(node) and node or nil end,
    extract = function(node) return { [elixir_kind(node)] = { '' } } end,
    -- `@moduledoc` goes inside the module, above its first line
    position = function(node)
      local row, col = node:range()
      if elixir_kind(node) ~= 'module' then return row, col end
      return row + 1, col + vim.fn.shiftwidth()
    end,
    lines = {
      { 'public', '@doc """' },
      { 'public', '$1' },
      { 'public', '"""' },
      { 'module', '@moduledoc """' },
      { 'module', '$1' },
      { 'module', '"""' },
      -- ExDoc drops the `@doc` of a private function, with a warning
      { 'private', '# $1' },
    },
  })
end

local function haskell()
  return build({
    name = 'haddock',
    parent = {
      func = { 'function', 'bind', 'signature' },
      class = { 'data_type', 'newtype', 'type_synonym', 'class', 'type_family' },
    },
    -- A binding of a `where` or a `let` is local and takes no documentation
    pick = function(node, types)
      if inside(node, { 'declarations', 'class_declarations' }) then
        return of_type(node, types)
      end
    end,
    -- Above the type signature, which comes before the equations
    position = function(node)
      local prev = node:prev_named_sibling()
      local name, signature =
        node:field('name')[1], prev and prev:field('name')[1]
      if
        prev
        and prev:type() == 'signature'
        and name
        and signature
        and text(name) == text(signature)
      then
        node = prev
      end
      return node:range()
    end,
    lines = { { nil, '-- | $1', { no_results = true } } },
  })
end

local function scala()
  return build({
    name = 'scaladoc',
    parent = {
      func = { 'function_definition', 'function_declaration' },
      class = {
        'class_definition',
        'object_definition',
        'trait_definition',
        'enum_definition',
      },
    },
    extract = function(node)
      local data = { tparams = {}, params = {}, ['return'] = {} }
      for child in node:iter_children() do
        local kind = child:type()
        if kind == 'type_parameters' then
          for _, name in ipairs(child:field('name')) do
            data.tparams[#data.tparams + 1] = text(name)
          end
        elseif kind == 'parameters' then
          vim.list_extend(data.params, names(child, 'parameter'))
        elseif kind == 'class_parameters' then
          vim.list_extend(data.params, names(child, 'class_parameter'))
        end
      end
      local ret = node:field('return_type')[1]
      if ret and text(ret) ~= 'Unit' then data['return'] = { '' } end
      return found(data)
    end,
    lines = {
      { nil, '/** $1 */', { no_results = true } },
      { nil, '/** $1' },
      { nil, '  *' },
      { 'tparams', '  * @tparam %s $1' },
      { 'params', '  * @param %s $1' },
      { 'return', '  * @return $1' },
      { nil, '  */' },
    },
  })
end

local function swift()
  return build({
    name = 'docc',
    parent = {
      func = {
        'function_declaration',
        'init_declaration',
        'protocol_function_declaration',
        'subscript_declaration',
      },
      class = { 'class_declaration', 'protocol_declaration' },
    },
    extract = function(node)
      local data = { params = {}, ['return'] = {}, throws = {} }
      for child in node:iter_children() do
        local kind = child:type()
        if kind == 'parameter' then
          -- `name` holds the type as well; the argument label is a field of
          -- its own
          for _, name in ipairs(child:field('name')) do
            if name:type() == 'simple_identifier' then
              data.params[#data.params + 1] = text(name)
            end
          end
        elseif kind == '->' then
          data['return'] = { '' }
        elseif kind == 'throws' then
          data.throws = { '' }
        end
      end
      return found(data)
    end,
    lines = {
      { nil, '/// $1', { no_results = true } },
      { nil, '/// $1' },
      { nil, '///' },
      {
        'params',
        '///   - %s: $1',
        { before_first_item = { '/// - Parameters:' } },
      },
      { 'return', '/// - Returns: $1' },
      { 'throws', '/// - Throws: $1' },
    },
  })
end

--- The Zig nodes whose declarations take a doc comment
local ZIG_CONTAINERS = {
  'source_file',
  'struct_declaration',
  'enum_declaration',
  'union_declaration',
  'opaque_declaration',
}

local function zig()
  return build({
    name = 'zigdoc',
    parent = {
      func = { 'function_declaration' },
      class = { 'variable_declaration', 'container_field' },
      file = { 'source_file' },
    },
    -- A doc comment on a local variable does not compile
    pick = function(node, types)
      if node:type() == 'source_file' or inside(node, ZIG_CONTAINERS) then
        return of_type(node, types)
      end
    end,
    lines = {
      { nil, '//! $1', { no_results = true, type = { 'file' } } },
      { nil, '/// $1', { no_results = true, type = { 'func', 'class' } } },
    },
  })
end

local function r()
  return build({
    name = 'roxygen2',
    parent = { func = { 'binary_operator' } },
    -- roxygen2 documents the assignment naming a function, not the function
    pick = function(node)
      local parent = node:type() == 'function_definition' and node:parent()
      local rhs = parent
        and parent:type() == 'binary_operator'
        and parent:field('rhs')[1]
      if rhs and rhs:equal(node) then return parent end
    end,
    extract = function(node)
      local fn = node:field('rhs')[1]
      return found({
        params = names(fn:field('parameters')[1], 'parameter'),
        ['return'] = { '' },
      })
    end,
    lines = {
      { nil, "#' $1" },
      { nil, "#'" },
      { 'params', "#' @param %s $1" },
      { 'return', "#' @return $1" },
    },
  })
end

local function gleam()
  return build({
    name = 'gleamdoc',
    parent = {
      func = { 'function' },
      class = { 'type_definition', 'type_alias', 'constant' },
      file = { 'source_file' },
    },
    lines = {
      { nil, '//// $1', { no_results = true, type = { 'file' } } },
      { nil, '/// $1', { no_results = true, type = { 'func', 'class' } } },
    },
  })
end

local function ocaml()
  return build({
    name = 'odoc',
    parent = {
      func = { 'value_definition' },
      class = {
        'type_definition',
        'module_definition',
        'module_type_definition',
        'exception_definition',
        'external',
      },
    },
    -- A `let ... in` is local and takes no documentation
    pick = function(node, types)
      if inside(node, { 'compilation_unit', 'structure' }) then
        return of_type(node, types)
      end
    end,
    extract = function(node)
      local params = {}
      local binding = node:named_child(0)
      if binding and binding:type() == 'let_binding' then
        for child in binding:iter_children() do
          local pattern = child:type() == 'parameter'
            and child:field('pattern')[1]
          -- `()` and destructuring patterns name no parameter
          if pattern and pattern:type() == 'value_pattern' then
            params[#params + 1] = text(pattern)
          end
        end
      end
      return found({ params = params })
    end,
    lines = {
      { nil, '(** $1 *)', { no_results = true } },
      { nil, '(** $1' },
      { 'params', '    @param %s $1' },
      { nil, '*)' },
    },
  })
end

local function perl()
  return build({
    name = 'pod',
    parent = {
      func = { 'subroutine_declaration_statement' },
      class = { 'package_statement' },
    },
    extract = function(node)
      local name = node:field('name')[1]
      return { name = { name and text(name) or '' } }
    end,
    -- A POD command only counts at the start of a line
    position = function(node) return (node:range()), 0 end,
    lines = {
      { 'name', '=head2 %s', { type = { 'func' } } },
      { 'name', '=head1 NAME', { type = { 'class' } } },
      { nil, '' },
      { 'name', '$1', { type = { 'func' } } },
      { 'name', '%s - $1', { type = { 'class' } } },
      { nil, '' },
      { nil, '=cut' },
      { nil, '' },
    },
  })
end

local function fish()
  return build({
    -- Fish has no convention of its own; this is the shdoc of the bash scripts
    name = 'fishdoc',
    parent = { func = { 'function_definition' } },
    extract = function(node)
      local args, naming = {}, false
      for _, option in ipairs(node:field('option')) do
        local word = text(option)
        if word == '--argument-names' or word == '-a' then
          naming = true
        elseif word:sub(1, 1) == '-' then
          naming = false
        elseif naming then
          args[#args + 1] = word
        end
      end
      return found({ args = args })
    end,
    lines = {
      { nil, '# @description $1', { no_results = true } },
      { nil, '# @description $1' },
      { 'args', '# @arg %s $1' },
    },
  })
end

--- Neogen strips the literal string `$1` from a rendered line and turns it into
--- a jump mark, so an `@arg $1` written straight into a template comes out
--- empty. The shell templates write this sentinel instead, and
--- `M.install_arg_sentinel_fixup` turns it back into an escaped `$` once the
--- snippet has been rendered.
local ARG_SENTINEL = '__SHDOC_ARG'

--- Collect the names `dybatpho::expect_args` gives the arguments of a function.
--- @param node TSNode The `function_definition` node
--- @return table args One entry per named argument, with its position
--- @return boolean declared Whether the function calls `expect_args` at all,
---   which it may do while naming nothing to say that it takes no arguments
local function extract_expect_args(node)
  local args = {}
  local declared = false
  local idx = 1
  -- Iterate child nodes of function_definition
  for child in node:iter_children() do
    if child:type() == 'compound_statement' then
      for stmt in child:iter_children() do
        if stmt:type() == 'command' then
          local command_name_node = nil
          for subchild in stmt:iter_children() do
            if subchild:type() == 'command_name' then
              command_name_node = subchild
              break
            end
          end
          if
            command_name_node
            and text(command_name_node) == 'dybatpho::expect_args'
          then
            declared = true
            for subchild in stmt:iter_children() do
              if subchild:type() == 'word' then
                local arg = text(subchild)
                if arg == '--' then goto end_func end
                table.insert(args, {
                  arg = { arg },
                  index = { idx },
                })
                idx = idx + 1
              end
            end
          end
        end
      end
    end
  end
  ::end_func::
  return args, declared
end

--- Collect the positional parameters a function body actually reads, which is
--- how a script that does not source dybatpho takes its arguments. `$1` and
--- `${1}` are the same parameter, and `$@` is reported last, the way it is
--- written in a signature.
--- @param node TSNode The `function_definition` node
--- @return table positionals One entry per parameter, in numeric order
local function extract_positionals(node)
  local body = nil
  for child in node:iter_children() do
    if child:type() == 'compound_statement' then body = child end
  end
  if not body then return {} end

  local source = text(body)
  local seen, order = {}, {}
  for _, pattern in ipairs({ '%$([0-9]+)', '%${([0-9]+)}' }) do
    for token in source:gmatch(pattern) do
      if not seen[token] then
        seen[token] = true
        table.insert(order, tonumber(token))
      end
    end
  end
  table.sort(order)

  local positionals = {}
  for _, number in ipairs(order) do
    table.insert(positionals, { positional = { tostring(number) } })
  end
  if source:find('%$@') or source:find('%${@}') then
    table.insert(positionals, { positional = { '@' } })
  end
  return positionals
end

--- Whether line 1 of the current buffer is a shebang
---@return boolean
local function has_shebang()
  return (vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ''):sub(1, 2) == '#!'
end

--- Neogen's `sh` configuration, made over in the dybatpho house style.
--- @param shell? string The interpreter of the file banner's shebang; none
---   for a file sourced by a tool (`PKGBUILD`, an ebuild), not run
--- @return table
local function sh(shell)
  -- A copy each: the filetypes differ in their shebang
  local config = vim.deepcopy(require('neogen.configurations.sh'))

  -- `dybatpho::expect_args` is the authoritative signature when it is there,
  -- so the positional scan is only a fallback for a function that does not use
  -- it. Reporting both would double up: `expect_args name path -- "$@"` ends
  -- in `$@`, which the scan would pick up as an argument of its own.
  --
  -- An empty key still counts as a result, which would keep the `no_results`
  -- rows of the template -- `@noargs` among them -- from ever firing, so a key
  -- is reported only when something was actually found.
  config.data.func['function_definition']['0'].extract = function(node)
    local args, declared = extract_expect_args(node)
    if declared then
      -- `expect_args -- "$@"` names nothing on purpose: the function takes no
      -- arguments. Falling through to the scan would report the `$@` of that
      -- very line as one.
      return #args > 0 and { args = args } or {}
    end

    local positionals = extract_positionals(node)
    if #positionals > 0 then return { positionals = positionals } end

    return {}
  end

  -- The banner rows render only with a result, which `banner` always is; the
  -- shebang comes along only when line 1 is not one already, so it never
  -- changes the interpreter of a script.
  config.data.file.program['0'].extract = function()
    return {
      banner = { '' },
      shebang = shell and not has_shebang() and { shell } or nil,
    }
  end

  config.template = {
    use_default_comment = false,
    -- The banner goes after a shebang, which only counts on line 1
    position = function(_, kind)
      if kind == 'file' and has_shebang() then return 1, 0 end
    end,
    annotation_convention = 'sh_docs',

    -- The dybatpho house style: banner comments, and arguments named by
    -- `dybatpho::expect_args`.
    sh_docs = {
      { 'shebang', '#!/usr/bin/env %s', { type = { 'file' } } },
      { nil, '# @file $1', { type = { 'file' } } },
      { nil, '# @brief $1', { type = { 'file' } } },
      { nil, '# @description $1', { type = { 'file' } } },
      { nil, '', { type = { 'file' } } },

      -- A row without `no_results` is only rendered when the extractor found
      -- something, so the banners of the two cases cannot be shared: each block
      -- carries its own pair.
      {
        nil,
        '#######################################',
        { no_results = true, type = { 'func' } },
      },
      { nil, '# @description $1', { no_results = true, type = { 'func' } } },
      { nil, '# @noargs', { no_results = true, type = { 'func' } } },
      { nil, '# @stdout $1', { no_results = true, type = { 'func' } } },
      { nil, '# @exitcode 0 $1', { no_results = true, type = { 'func' } } },
      { nil, '# @exitcode 1 $1', { no_results = true, type = { 'func' } } },
      {
        nil,
        '#######################################',
        { no_results = true, type = { 'func' } },
      },

      { nil, '#######################################', { type = { 'func' } } },
      { nil, '# @description $1', { type = { 'func' } } },
      -- Arguments named by `dybatpho::expect_args`: the name seeds the
      -- description, the way the existing sources read.
      {
        { 'index', 'arg' },
        '# @arg ' .. ARG_SENTINEL .. '%d@ string %s',
        {
          required = 'args',
          type = { 'func' },
        },
      },
      -- Arguments a function without `expect_args` reads positionally.
      {
        { 'positional' },
        '# @arg ' .. ARG_SENTINEL .. '%s@ string $1',
        {
          required = 'positionals',
          type = { 'func' },
        },
      },
      { nil, '# @stdout $1', { type = { 'func' } } },
      { nil, '# @exitcode 0 $1', { type = { 'func' } } },
      { nil, '# @exitcode 1 $1', { type = { 'func' } } },
      { nil, '#######################################', { type = { 'func' } } },
    },
  }
  return config
end

--- The shebang of each filetype the shell template serves
local SHEBANGS = { sh = 'bash', bats = 'bats', zsh = 'zsh' }

--- Swap the sentinel back for a literal `$` in every rendered annotation.
---
--- The hook sits on `to_snippet` rather than on a keymap of ours because that
--- is the one place every way of generating an annotation passes through: both
--- leader maps, `:Neogen`, and anything else that calls `neogen.generate`. A
--- wrapper around a single keymap leaves `__SHDOC_ARG1@` in the buffer for
--- every other entry point.
function M.install_arg_sentinel_fixup()
  local snippet = require('neogen.snippet')
  if snippet.__shdoc_arg_fixup then return end
  snippet.__shdoc_arg_fixup = true

  local to_snippet = snippet.to_snippet
  snippet.to_snippet = function(template, marks, pos)
    local lines = to_snippet(template, marks, pos)
    for index, line in ipairs(lines) do
      -- `\$` is how a literal dollar is escaped in an LSP snippet; the `$$`
      -- that neogen escapes with is read as a tabstop by LuaSnip.
      lines[index] = line:gsub(ARG_SENTINEL .. '(.-)@', '\\$%1')
    end
    return lines
  end
end

--- The conventions built here, by the name a `DyLangSpec.neogen` gives them,
--- each building the configuration of one filetype
---@type table<string, fun(ft: string): table>
M.BUILDERS = {
  dartdoc = dart,
  exdoc = elixir,
  fishdoc = fish,
  gleamdoc = gleam,
  haddock = haskell,
  odoc = ocaml,
  pod = perl,
  roxygen2 = r,
  scaladoc = scala,
  docc = swift,
  zigdoc = zig,
  sh_docs = function(ft) return sh(SHEBANGS[ft]) end,
}

--- Whether neogen ships a configuration of its own named `name`
---@param name string
---@return boolean
local function shipped(name)
  return (pcall(require, 'neogen.configurations.' .. name))
end

--- The languages of `config.languages` with a `neogen` convention, in sorted
--- order, as (filetypes, convention) pairs
---@return { [1]: string[], [2]: string }[]
local function conventions()
  local languages = require('config.languages')
  local names = vim.tbl_keys(languages)
  table.sort(names)
  local ret = {}
  for _, name in ipairs(names) do
    local spec = languages[name]
    if spec.neogen then ret[#ret + 1] = { spec.filetypes, spec.neogen } end
  end
  return ret
end

--- The filetypes whose annotations follow `convention`
---@param convention string
---@return string[]
function M.filetypes(convention)
  local ret = {}
  for _, entry in ipairs(conventions()) do
    if entry[2] == convention then vim.list_extend(ret, entry[1]) end
  end
  return ret
end

--- Every configuration, keyed by filetype, for neogen's `languages`, from the
--- `neogen` convention of each language. Neogen looks a configuration up by
--- the exact filetype, so `sh.PKGBUILD` or `typescript.tsx` needs one of its
--- own; a filetype neogen does serve keeps neogen's configuration, unless the
--- convention is one built here.
---@return table<string, table>
function M.languages()
  local ret = {}
  for _, entry in ipairs(conventions()) do
    local filetypes, convention = entry[1], entry[2]
    local build = M.BUILDERS[convention]
    for _, ft in ipairs(filetypes) do
      if build then
        ret[ft] = build(ft)
      elseif not shipped(ft) then
        ret[ft] = require('neogen.configurations.' .. convention)
      end
    end
  end
  return ret
end

return M
