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

  for _, case in ipairs(cases) do
    local ft, name = case[1], case[2]
    it(ft .. ': ' .. name, function()
      if not has_parser(ft) then
        return pending('no ' .. ft .. ' parser on this machine')
      end
      assert.are.same(case.expect, generate(ft, case.lines, case.cursor))
    end)
  end
end)
