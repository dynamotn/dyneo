local h = require('helpers')

-- Neogen is taken from lazy.nvim's install directory, and the parsers from
-- where nvim-treesitter installs them, when this machine has them.
local data = vim.fn.stdpath('data') --[[@as string]]
local neogen = vim.fs.joinpath(data, 'lazy', 'neogen')
local has_neogen = vim.uv.fs_stat(neogen) ~= nil
if has_neogen then vim.opt.rtp:append(neogen) end
vim.opt.rtp:append(vim.fs.joinpath(data, 'site'))
-- As `config.languages` registers it
vim.treesitter.language.register('bash', { 'sh', 'bats' })

---@param ft string
---@return boolean
local function has_parser(ft)
  local lang = vim.treesitter.language.get_lang(ft) or ft
  return (pcall(vim.treesitter.language.inspect, lang))
end

--- Generate an annotation in a scratch buffer of `ft` holding `lines`, with
--- the cursor at `cursor`, and return the lines of the buffer after it
---@param ft string
---@param lines string[]
---@param cursor integer[] (1,0)-indexed
---@return string[]
local function generate(ft, lines, cursor)
  local bufnr = h.buffer({ lines = lines })
  vim.api.nvim_set_current_buf(bufnr)
  vim.bo[bufnr].filetype = ft
  vim.bo[bufnr].expandtab = true
  vim.bo[bufnr].shiftwidth = 2
  vim.api.nvim_win_set_cursor(0, cursor)
  require('neogen').generate()
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, true)
end

describe('util.neogen', function()
  if not has_neogen then
    pending('neogen is not installed')
    return
  end

  local languages
  before_each(function()
    h.globals()
    h.unload('util.neogen')
    languages = require('util.neogen').languages()
    require('neogen').setup({
      languages = languages,
      -- Insert the lines as they are, without a session of jump marks
      input_after_comment = false,
    })
  end)

  it('hands a compound filetype the configuration of its dialect', function()
    assert.are.equal(
      require('neogen.configurations.typescriptreact'),
      languages['typescript.tsx']
    )
    assert.are.equal(
      require('neogen.configurations.javascriptreact'),
      languages['javascript.jsx']
    )
    -- A filetype neogen serves keeps neogen's own configuration
    assert.is_nil(languages.typescriptreact)
    assert.is_nil(languages.javascript)
  end)

  it('knows every convention config.languages names', function()
    local builders = require('util.neogen').BUILDERS
    for name, spec in pairs(require('config.languages')) do
      if spec.neogen then
        assert(
          builders[spec.neogen]
            or pcall(require, 'neogen.configurations.' .. spec.neogen),
          name .. ': no convention ' .. spec.neogen
        )
      end
    end
  end)

  ---@param ft string
  ---@return table<string, string[]>
  local function file_data(ft)
    return languages[ft].data.file.program['0'].extract()
  end

  it('gives every shell filetype the template, with its own shebang', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { 'echo hi' } }))
    assert.are.same({ 'bash' }, file_data('sh').shebang)
    assert.are.same({ 'bats' }, file_data('bats').shebang)
    assert.are.same({ 'zsh' }, file_data('zsh').shebang)
    -- Sourced by makepkg, not run
    assert.is_nil(file_data('sh.PKGBUILD').shebang)
    assert.is_nil(file_data('sh.ebuild').shebang)
    assert.is_nil(languages.sh.template.position(nil, 'file'))
  end)

  it('keeps the shebang of a script, with the banner below it', function()
    vim.api.nvim_set_current_buf(h.buffer({ lines = { '#!/bin/sh', 'x=1' } }))
    assert.are.same({ banner = { '' } }, file_data('sh'))
    assert.are.same({ 1, 0 }, { languages.sh.template.position(nil, 'file') })
  end)

  it(
    'leaves the sh configuration of neogen alone',
    function()
      assert.is_nil(require('neogen.configurations.sh').template.sh_docs)
    end
  )

  it('escapes the dollar of a shell argument in a snippet', function()
    require('util.neogen').install_arg_sentinel_fixup()
    local lines = require('neogen.snippet').to_snippet(
      { '# @arg __SHDOC_ARG1@ string name' },
      {},
      { 0, 0 }
    )
    assert.are.same({ '# @arg \\$1 string name' }, lines)
  end)

  ---@type { [1]: string, [2]: string, lines: string[], cursor: integer[], expect: string[] }[]
  local cases = {
    {
      'dart',
      'documents a method above its metadata, from inside its body',
      lines = {
        'class A {',
        '  @override',
        '  int add(int a, String b) {',
        '    return a;',
        '  }',
        '}',
      },
      cursor = { 4, 4 },
      expect = {
        'class A {',
        '  /// ',
        '  @override',
        '  int add(int a, String b) {',
        '    return a;',
        '  }',
        '}',
      },
    },
    {
      'elixir',
      'gives a public function a @doc, not the call in its body',
      lines = {
        'defmodule Foo do',
        '  def add(a, b) do',
        '    IO.puts(a)',
        '  end',
        'end',
      },
      cursor = { 3, 7 },
      expect = {
        'defmodule Foo do',
        '  @doc """',
        '  ',
        '  """',
        '  def add(a, b) do',
        '    IO.puts(a)',
        '  end',
        'end',
      },
    },
    {
      'elixir',
      'gives a private function a comment, which ExDoc does not drop',
      lines = { 'defmodule Foo do', '  defp sub(a), do: a', 'end' },
      cursor = { 2, 4 },
      expect = { 'defmodule Foo do', '  # ', '  defp sub(a), do: a', 'end' },
    },
    {
      'elixir',
      'puts the @moduledoc inside the module',
      lines = { 'defmodule Foo do', '  def a, do: 1', 'end' },
      cursor = { 1, 0 },
      expect = {
        'defmodule Foo do',
        '  @moduledoc """',
        '  ',
        '  """',
        '  def a, do: 1',
        'end',
      },
    },
    {
      'haskell',
      'documents a function above its signature, not a where binding',
      lines = {
        'add :: Int -> Int -> Int',
        'add a b = c',
        '  where',
        '    c = a + b',
      },
      cursor = { 4, 4 },
      expect = {
        '-- | ',
        'add :: Int -> Int -> Int',
        'add a b = c',
        '  where',
        '    c = a + b',
      },
    },
    {
      'haskell',
      'documents the first equation of a function from the last one',
      lines = {
        'fact :: Int -> Int',
        'fact 0 = 1',
        'fact 1 = 1',
        'fact n = n * fact (n - 1)',
      },
      cursor = { 4, 9 },
      expect = {
        '-- | ',
        'fact :: Int -> Int',
        'fact 0 = 1',
        'fact 1 = 1',
        'fact n = n * fact (n - 1)',
      },
    },
    {
      'scala',
      'lists type parameters, parameters and the return value',
      lines = { 'object O {', '  def f[A](a: A, b: Int): Int = b', '}' },
      cursor = { 2, 30 },
      expect = {
        'object O {',
        '  /** ',
        '    *',
        '    * @tparam A ',
        '    * @param a ',
        '    * @param b ',
        '    * @return ',
        '    */',
        '  def f[A](a: A, b: Int): Int = b',
        '}',
      },
    },
    {
      'scala',
      'leaves out the return value of a Unit method',
      lines = { 'object O {', '  def f(): Unit = ()', '}' },
      cursor = { 2, 6 },
      expect = {
        'object O {',
        '  /**  */',
        '  def f(): Unit = ()',
        '}',
      },
    },
    {
      'swift',
      'names parameters by their local name, with returns and throws',
      lines = {
        'func add(a: Int, _ b: String) throws -> Int {',
        '  return a',
        '}',
      },
      cursor = { 2, 2 },
      expect = {
        '/// ',
        '///',
        '/// - Parameters:',
        '///   - a: ',
        '///   - b: ',
        '/// - Returns: ',
        '/// - Throws: ',
        'func add(a: Int, _ b: String) throws -> Int {',
        '  return a',
        '}',
      },
    },
    {
      'swift',
      'documents what a typed throw throws',
      lines = { 'func f() throws(MyError) {}' },
      cursor = { 1, 5 },
      expect = {
        '/// ',
        '///',
        '/// - Throws: ',
        'func f() throws(MyError) {}',
      },
    },
    {
      'zig',
      'documents the function around a local, which takes none',
      lines = {
        'pub fn add(a: i32) i32 {',
        '    const x = a;',
        '    return x;',
        '}',
      },
      cursor = { 2, 10 },
      expect = {
        '/// ',
        'pub fn add(a: i32) i32 {',
        '    const x = a;',
        '    return x;',
        '}',
      },
    },
    {
      'r',
      'documents the assignment naming a function with roxygen2',
      lines = { 'add <- function(a, b = 2, ...) {', '  a + b', '}' },
      cursor = { 2, 2 },
      expect = {
        "#' ",
        "#'",
        "#' @param a ",
        "#' @param b ",
        "#' @param ... ",
        "#' @return ",
        'add <- function(a, b = 2, ...) {',
        '  a + b',
        '}',
      },
    },
    {
      'r',
      'documents a function from its name',
      lines = { 'add <- function(a) {', '  a', '}' },
      cursor = { 1, 1 },
      expect = {
        "#' ",
        "#'",
        "#' @param a ",
        "#' @return ",
        'add <- function(a) {',
        '  a',
        '}',
      },
    },
    {
      'r',
      'documents a function assigned with =',
      lines = { 'add = function(a) a' },
      cursor = { 1, 1 },
      expect = {
        "#' ",
        "#'",
        "#' @param a ",
        "#' @return ",
        'add = function(a) a',
      },
    },
    {
      'gleam',
      'documents a function',
      lines = { 'pub fn add(a: Int) -> Int {', '  a', '}' },
      cursor = { 2, 2 },
      expect = { '/// ', 'pub fn add(a: Int) -> Int {', '  a', '}' },
    },
    {
      'ocaml',
      'documents the top-level let around a local one, with its parameters',
      lines = { 'let add a b =', '  let z = a + b in', '  z' },
      cursor = { 2, 6 },
      expect = {
        '(** ',
        '    @param a ',
        '    @param b ',
        '*)',
        'let add a b =',
        '  let z = a + b in',
        '  z',
      },
    },
    {
      'perl',
      'writes POD for a subroutine at the start of the line',
      lines = { 'sub add {', '  return 1;', '}' },
      cursor = { 2, 2 },
      expect = {
        '=head2 add',
        '',
        '',
        '',
        '=cut',
        '',
        'sub add {',
        '  return 1;',
        '}',
      },
    },
    {
      'fish',
      'names the arguments of --argument-names',
      lines = {
        'function add --argument-names a b --description x',
        '  echo hi',
        'end',
      },
      cursor = { 2, 2 },
      expect = {
        '# @description ',
        '# @arg a ',
        '# @arg b ',
        'function add --argument-names a b --description x',
        '  echo hi',
        'end',
      },
    },
  }

  cases[#cases + 1] = {
    'zsh',
    'reads the positional parameters of a zsh function',
    lines = { 'foo() {', '  echo "$1" "$2"', '}' },
    cursor = { 2, 2 },
    -- Without a snippet engine the sentinel stays; the fixup works on snippets
    expect = {
      '#######################################',
      '# @description ',
      '# @arg __SHDOC_ARG1@ string ',
      '# @arg __SHDOC_ARG2@ string ',
      '# @stdout ',
      '# @exitcode 0 ',
      '# @exitcode 1 ',
      '#######################################',
      'foo() {',
      '  echo "$1" "$2"',
      '}',
    },
  }

  vim.list_extend(cases, {
    {
      'sh',
      'writes a shebang above the banner of a script with none',
      lines = { 'x=1' },
      cursor = { 1, 0 },
      expect = {
        '#!/usr/bin/env bash',
        '# @file ',
        '# @brief ',
        '# @description ',
        '',
        'x=1',
      },
    },
    {
      'sh',
      'keeps the shebang of a script, with the banner below it',
      lines = { '#!/bin/sh', '', 'x=1' },
      cursor = { 3, 0 },
      expect = {
        '#!/bin/sh',
        '# @file ',
        '# @brief ',
        '# @description ',
        '',
        '',
        'x=1',
      },
    },
    {
      'bats',
      'writes the banner of a test file below its shebang',
      lines = { '#!/usr/bin/env bats', '@test "x" {', '  run foo', '}' },
      cursor = { 3, 2 },
      expect = {
        '#!/usr/bin/env bats',
        '# @file ',
        '# @brief ',
        '# @description ',
        '',
        '@test "x" {',
        '  run foo',
        '}',
      },
    },
    {
      'sh',
      'reads the parameters a function expands, not a $1 of awk',
      lines = { 'foo() {', [[  awk '{print $1}' "${2:-x}" "$@"]], '}' },
      cursor = { 2, 2 },
      expect = {
        '#######################################',
        '# @description ',
        '# @arg __SHDOC_ARG2@ string ',
        '# @arg __SHDOC_ARG@@ string ',
        '# @stdout ',
        '# @exitcode 0 ',
        '# @exitcode 1 ',
        '#######################################',
        'foo() {',
        [[  awk '{print $1}' "${2:-x}" "$@"]],
        '}',
      },
    },
  })

  vim.list_extend(cases, {
    {
      'sh',
      'names the arguments dybatpho::expect_args declares',
      lines = {
        'foo() {',
        '  dybatpho::expect_args name path -- "$@"',
        '  echo "$1" "$3"',
        '}',
      },
      cursor = { 3, 2 },
      expect = {
        '#######################################',
        '# @description ',
        '# @arg __SHDOC_ARG1@ string name',
        '# @arg __SHDOC_ARG2@ string path',
        '# @stdout ',
        '# @exitcode 0 ',
        '# @exitcode 1 ',
        '#######################################',
        'foo() {',
        '  dybatpho::expect_args name path -- "$@"',
        '  echo "$1" "$3"',
        '}',
      },
    },
    {
      'sh',
      'takes an empty expect_args at its word, not the $@ it passes',
      lines = { 'foo() {', '  dybatpho::expect_args -- "$@"', '}' },
      cursor = { 2, 2 },
      expect = {
        '#######################################',
        '# @description ',
        '# @noargs',
        '# @stdout ',
        '# @exitcode 0 ',
        '# @exitcode 1 ',
        '#######################################',
        'foo() {',
        '  dybatpho::expect_args -- "$@"',
        '}',
      },
    },
    {
      'sh',
      'documents a function reading no argument as taking none',
      lines = { 'foo() {', '  echo hi', '}' },
      cursor = { 2, 2 },
      expect = {
        '#######################################',
        '# @description ',
        '# @noargs',
        '# @stdout ',
        '# @exitcode 0 ',
        '# @exitcode 1 ',
        '#######################################',
        'foo() {',
        '  echo hi',
        '}',
      },
    },
  })

  for _, case in ipairs(cases) do
    local ft, name = case[1], case[2]
    it(ft .. ': ' .. name, function()
      if not has_parser(ft) then
        -- CI builds every parser a case needs (`scripts/install-parsers.lua`),
        -- so one missing there is a case that would test nothing
        assert(not vim.env.CI, 'no ' .. ft .. ' parser on CI')
        return pending('no ' .. ft .. ' parser on this machine')
      end
      assert.are.same(case.expect, generate(ft, case.lines, case.cursor))
    end)
  end

  -- The extractors read a few methods of a node, so a tree shaped like the
  -- grammar's stands in for a parser the machine may not have: what the
  -- real parsers say is the language cases' business.
  describe('on a tree of the grammar', function()
    local restore

    ---@class DyFakeNode
    ---@field kind string
    ---@field text string
    ---@field fields table<string, DyFakeNode[]>
    ---@field children DyFakeNode[]
    ---@field prev? DyFakeNode
    ---@field parent_node? DyFakeNode
    ---@field row integer
    ---@field col integer

    --- A node of type `kind`, with the children, fields and text given
    ---@param kind string
    ---@param opts? { text?: string, fields?: table<string, DyFakeNode[]>, children?: DyFakeNode[], prev?: DyFakeNode, row?: integer, col?: integer }
    ---@return DyFakeNode
    local function node(kind, opts)
      opts = opts or {}
      local n = {
        kind = kind,
        text = opts.text or '',
        fields = opts.fields or {},
        children = opts.children or {},
        prev = opts.prev,
        row = opts.row or 0,
        col = opts.col or 0,
      }
      function n:type() return self.kind end
      function n:field(name) return self.fields[name] or {} end
      function n:iter_children()
        local i = 0
        return function()
          i = i + 1
          return self.children[i]
        end
      end
      function n:parent() return self.parent_node end
      function n:prev_named_sibling() return self.prev end
      function n:named_child(i) return self.children[i + 1] end
      function n:range() return self.row, self.col end
      for _, child in ipairs(n.children) do
        child.parent_node = n
      end
      for _, list in pairs(n.fields) do
        for _, child in ipairs(list) do
          child.parent_node = child.parent_node or n
        end
      end
      return n
    end

    --- Put `child` inside a node of `kind`
    ---@param kind string
    ---@param child DyFakeNode
    ---@return DyFakeNode child
    local function within(kind, child)
      node(kind, { children = { child } })
      return child
    end

    before_each(function()
      restore = h.stub(
        vim.treesitter,
        'get_node_text',
        function(n) return n.text end
      )
    end)
    after_each(function() restore() end)

    --- The parts of the configuration of `ft` the specs reach
    ---@param ft string
    ---@param kind string
    ---@return fun(node: DyFakeNode): table extract
    ---@return fun(node: DyFakeNode, types: string[]): DyFakeNode? locate
    ---@return fun(node: DyFakeNode, kind: string): integer, integer position
    local function parts(ft, kind)
      local config = languages[ft]
      local extract =
        config.data[kind][table.concat(config.parent[kind], '|')]['0'].extract
      local locate = function(n, types)
        return config.locator({ current = n }, types or config.parent[kind])
      end
      return extract, locate, config.template.position
    end

    it('dart: documents a method from its body, above its metadata', function()
      local extract, locate, position = parts('dart', 'func')
      local annotation = node('annotation', { row = 1 })
      local signature = node('function_signature', { row = 2 })
      local method = node('method_signature', {
        prev = annotation,
        children = { signature },
      })
      local body = node('function_body', { prev = method })
      node('class_body', { children = { method, body } })
      assert.are.equal(method, locate(body))
      -- From the name: the signature is wrapped, the method is documented
      assert.are.equal(method, locate(signature))
      -- A body with nothing before it is no method
      assert.is_nil(locate(node('function_body')))
      assert.are.same({ 1, 0 }, { position(method) })
      assert.are.same({ 2, 0 }, { position(signature) })
      assert.are.same({}, extract(method))
    end)

    it('elixir: tells a definition from any other call', function()
      local extract, locate, position = parts('elixir', 'func')
      local puts = node('call', {
        fields = { target = { node('dot', { text = 'IO.puts' }) } },
      })
      local def = node('call', {
        row = 3,
        col = 2,
        fields = { target = { node('identifier', { text = 'defp' }) } },
        children = { node('do_block', { children = { puts } }) },
      })
      local module = node('call', {
        row = 0,
        fields = { target = { node('identifier', { text = 'defmodule' }) } },
        children = { node('do_block', { children = { def } }) },
      })
      assert.are.equal(def, locate(puts))
      assert.are.same({ private = { '' } }, extract(def))
      assert.are.same({ module = { '' } }, extract(module))
      assert.are.same({ 3, 2 }, { position(def) })
      vim.bo.shiftwidth = 4
      assert.are.same({ 1, 4 }, { position(module) })
    end)

    it('haskell: documents a declaration above its signature', function()
      local _, locate, position = parts('haskell', 'func')
      local other = node('function', {
        row = 0,
        fields = { name = { node('variable', { text = 'other' }) } },
      })
      local signature = node('signature', {
        row = 1,
        prev = other,
        fields = { name = { node('variable', { text = 'fact' }) } },
      })
      local first = node('function', {
        row = 2,
        prev = signature,
        fields = { name = { node('variable', { text = 'fact' }) } },
      })
      local last = node('function', {
        row = 3,
        prev = first,
        fields = { name = { node('variable', { text = 'fact' }) } },
      })
      local declarations =
        node('declarations', { children = { other, signature, first, last } })
      assert.are.equal(last, locate(last))
      assert.are.same({ 1, 0 }, { position(last) })
      -- Without a signature, above the first equation of that name
      local unsigned = node('function', {
        row = 5,
        prev = last,
        fields = { name = { node('variable', { text = 'other' }) } },
      })
      within('declarations', unsigned)
      assert.are.same({ 5, 0 }, { position(unsigned) })
      -- A nameless binding stays where it is
      local pattern = node('bind', { row = 6, prev = last })
      assert.are.same({ 6, 0 }, { position(pattern) })
      -- A binding of a `where` is local
      local where = node('bind', {
        fields = { name = { node('variable', { text = 'c' }) } },
      })
      node('where', { children = { where } })
      assert.is_nil(locate(where))
      assert.is_not_nil(declarations)
    end)

    it('scala: lists type parameters, parameters and the return', function()
      local extract = parts('scala', 'func')
      local method = node('function_definition', {
        fields = { return_type = { node('type_identifier', { text = 'Int' }) } },
        children = {
          node('type_parameters', {
            fields = { name = { node('identifier', { text = 'A' }) } },
          }),
          node('parameters', {
            children = {
              node('parameter', {
                fields = { name = { node('identifier', { text = 'a' }) } },
              }),
              node(',', { text = ',' }),
            },
          }),
        },
      })
      assert.are.same(
        { tparams = { 'A' }, params = { 'a' }, ['return'] = { '' } },
        extract(method)
      )
      local class = node('class_definition', {
        children = {
          node('class_parameters', {
            children = {
              node('class_parameter', {
                fields = { name = { node('identifier', { text = 'x' }) } },
              }),
            },
          }),
        },
      })
      assert.are.same({ params = { 'x' } }, extract(class))
      local unit = node('function_definition', {
        fields = {
          return_type = { node('type_identifier', { text = 'Unit' }) },
        },
      })
      assert.are.same({}, extract(unit))
    end)

    it('swift: names parameters by their local name', function()
      local extract = parts('swift', 'func')
      local fn = node('function_declaration', {
        children = {
          node('parameter', {
            fields = {
              name = {
                node('simple_identifier', { text = 'a' }),
                node('user_type', { text = 'Int' }),
              },
            },
          }),
          node('throws', { text = 'throws' }),
          node('->', { text = '->' }),
        },
      })
      assert.are.same(
        { params = { 'a' }, ['return'] = { '' }, throws = { '' } },
        extract(fn)
      )
      local typed = node('function_declaration', {
        children = { node('throws_clause', { text = 'throws(E)' }) },
      })
      assert.are.same({ throws = { '' } }, extract(typed))
    end)

    it('zig: documents only what a container declares', function()
      local _, locate = parts('zig', 'func')
      local fn = within('struct_declaration', node('function_declaration'))
      assert.are.equal(fn, locate(fn))
      local file = node('source_file')
      assert.are.equal(file, locate(file, { 'source_file' }))
      local nested = within('block', node('function_declaration'))
      assert.is_nil(locate(nested))
    end)

    it('r: documents the assignment of a function', function()
      local extract, locate = parts('r', 'func')
      local params = node('parameters', {
        children = {
          node('parameter', {
            fields = { name = { node('identifier', { text = 'a' }) } },
          }),
        },
      })
      local fn = node('function_definition', {
        fields = { parameters = { params } },
      })
      local assignment = node('binary_operator', {
        fields = {
          operator = { node('<-', { text = '<-' }) },
          rhs = { fn },
        },
      })
      assert.are.equal(assignment, locate(fn))
      assert.are.same(
        { params = { 'a' }, ['return'] = { '' } },
        extract(assignment)
      )
      -- A function with no parameter list
      local bare = node('binary_operator', {
        fields = {
          operator = { node('=', { text = '=' }) },
          rhs = { node('function_definition') },
        },
      })
      assert.are.same({ ['return'] = { '' } }, extract(bare))
      -- Neither a sum nor a function given a name
      local sum = node('binary_operator', {
        fields = {
          operator = { node('+', { text = '+' }) },
          rhs = { node('identifier', { text = 'b' }) },
        },
      })
      assert.is_nil(locate(sum))
      assert.is_nil(locate(node('function_definition')))
    end)

    it('ocaml: names the parameters of a top-level let', function()
      local extract, locate = parts('ocaml', 'func')
      local binding = node('let_binding', {
        children = {
          node('value_name', { text = 'add' }),
          node('parameter', {
            fields = { pattern = { node('value_pattern', { text = 'a' }) } },
          }),
          node('parameter', {
            fields = { pattern = { node('unit', { text = '()' }) } },
          }),
        },
      })
      local definition = within(
        'compilation_unit',
        node('value_definition', { children = { binding } })
      )
      assert.are.equal(definition, locate(definition))
      assert.are.same({ params = { 'a' } }, extract(definition))
      -- A type carries no parameters
      assert.are.same(
        {},
        extract(
          node('type_definition', { children = { node('type_binding') } })
        )
      )
      -- A `let ... in` is local
      local inner = within('let_expression', node('value_definition'))
      assert.is_nil(locate(inner))
    end)

    it('perl: heads the POD with the name, at the start of the line', function()
      local extract, _, position = parts('perl', 'func')
      local sub = node('subroutine_declaration_statement', {
        row = 4,
        col = 2,
        fields = { name = { node('bareword', { text = 'add' }) } },
      })
      assert.are.same({ name = { 'add' } }, extract(sub))
      assert.are.same(
        { name = { '' } },
        extract(node('subroutine_declaration_statement'))
      )
      assert.are.same({ 4, 0 }, { position(sub) })
    end)

    it('fish: names the arguments of --argument-names', function()
      local extract = parts('fish', 'func')
      local fn = node('function_definition', {
        fields = {
          option = {
            node('word', { text = '-a' }),
            node('word', { text = 'a' }),
            node('word', { text = '--description' }),
            node('word', { text = 'x' }),
          },
        },
      })
      assert.are.same({ args = { 'a' } }, extract(fn))
      assert.are.same({}, extract(node('function_definition')))
    end)
  end)
end)
