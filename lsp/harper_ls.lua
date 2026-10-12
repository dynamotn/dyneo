-- Harper picks its parser from the LSP `languageId`, and Neovim sends the
-- filetype verbatim. A filetype Harper does not know is silently dropped, so
-- every filetype whose name differs from Harper's own identifier is translated
-- here. Anything absent from this table is already spelled the way Harper
-- expects, or has no parser at all -- those languages are covered by `ltcc`.
---@type table<string, string>
local language_ids = {
  -- Harper calls the Bash grammar `shellscript`, and it reads a Zsh script
  -- well enough, both writing their comments with `#`
  bats = 'shellscript',
  sh = 'shellscript',
  ['sh.ebuild'] = 'shellscript',
  ['sh.eclass'] = 'shellscript',
  ['sh.install'] = 'shellscript',
  ['sh.PKGBUILD'] = 'shellscript',
  zsh = 'shellscript',
  -- Spelled out, unlike the filetype
  cs = 'csharp',
  -- Compound filetypes, checked as their base language
  ['javascript.jsx'] = 'javascriptreact',
  ['markdown.mdx'] = 'markdown',
  ['typescript.tsx'] = 'typescriptreact',
  -- No grammar of their own, so lend them the closest one Harper has. The
  -- markup languages all wrap HTML, and Harper reads the prose between the
  -- tags; a template directive it cannot place is prose to it too, so the odd
  -- false positive here is the price of checking the copy at all.
  arduino = 'cpp',
  astro = 'html',
  blade = 'html',
  eruby = 'html',
  handlebars = 'html',
  heex = 'html',
  htmlangular = 'html',
  htmldjango = 'html',
  jinja = 'html',
  svelte = 'html',
  templ = 'html',
  twig = 'html',
  vue = 'html',
}

-- Harper reads every comment as prose, including the ones written for another
-- tool, and it has no setting to skip them -- only `harper:ignore` around a
-- block. Each pattern below marks the span of such a directive on its line,
-- and a diagnostic that starts inside one is dropped. The prose that follows
-- a `LuaLS` or `sh-docs` tag is still checked, only the tag and its names are
-- not.
---@type string[]
local tag_patterns = {
  -- An enum value of a `LuaLS` `@alias`, and an inline cast
  '%-%-%-|[^#]*',
  '%-%-%[%[@.-%]%]',
  -- The `sh-docs` tags of a shell library (github.com/dynamotn/sh-docs), with
  -- the name and type fields they take. A `@license` holds an identifier and
  -- a `@see` a reference, so neither has prose to check; `@option` is matched
  -- by `sh_docs_option` instead, since its spelling has no fixed length.
  '^%s*#%s*@arg%s+%S+%s+%S+',
  '^%s*#%s*@env%s+%S+%s+%S+',
  '^%s*#%s*@set%s+%S+%s+%S+',
  '^%s*#%s*@exitcode%s+%S+',
  '^%s*#%s*@file%s+%S+',
  '^%s*#%s*@name%s+%S+',
  '^%s*#%s*@namespace%s+%S+',
  '^%s*#%s*@license.*',
  '^%s*#%s*@see.*',
  '^%s*#%s*@%a+',
  -- A `dyshellint` exception and a `kcov(skip)` marker the way `dybatpho`
  -- writes them, both followed by a reason that is prose
  '#%s*dyshellint%s+%S+',
  '#%s*kcov%(%a+%)',
  -- A Haskell pragma, `{-# LANGUAGE ... #-}`
  '{%-#.-#%-}',
}

-- The directives of other tools, each written as what follows the comment
-- leader, so that one entry serves every language: `# noqa` and `-- noqa`
-- alike. A directive runs to the end of the line, reason and all, unless its
-- entry is anchored with `$`. An entry starting with `!` must follow the
-- leader with no space, as Go writes `//go:generate` and `//nolint`.
---@type string[]
local directives = {
  -- Lua
  'stylua:',
  'luacheck:',
  'selene:',
  'luacov:',
  -- Shell
  'shellcheck%s',
  'bats%s+%a+_tags=',
  -- Python
  'noqa%f[^%w]',
  'type:%s*ignore',
  'pyright:',
  'mypy:',
  'pylint:',
  'ruff:',
  'isort:',
  'flake8:',
  'fmt:%s*%a+',
  'yapf:',
  'autopep8:',
  'pragma:',
  'nosec%f[^%w]',
  '#nosec%f[^%w]',
  'pytype:',
  'pyre%-ignore',
  'pyre%-fixme',
  'pyre%-strict',
  'pyre%-unsafe',
  -- JavaScript, TypeScript, and CSS
  'eslint%-disable',
  'eslint%-enable',
  'eslint%-env%s',
  'eslint%s',
  'jshint%s',
  'jslint%s',
  'tslint:',
  '@ts%-ignore',
  '@ts%-expect%-error',
  '@ts%-nocheck',
  '@ts%-check',
  'prettier%-ignore',
  'biome%-ignore',
  'deno%-lint%-ignore',
  'deno%-fmt%-ignore',
  'dprint%-ignore',
  'oxlint%-disable',
  'oxlint%-enable',
  'stylelint%-disable',
  'stylelint%-enable',
  'istanbul%s',
  'c8%s',
  'v8%s+ignore',
  'webpack%u%a*:',
  '@vite%-ignore',
  '@jest%-environment',
  '@vitest%-environment',
  '@flow%f[^%w]',
  '@jsx%f[^%w]',
  '@jsxImportSource',
  '[#@]%s*sourceMappingURL=',
  '<reference%s',
  '%$FlowFixMe',
  -- Go
  '!go:%l',
  '!nolint',
  '!lint:',
  '!revive:',
  '!export%s',
  '!line%s',
  '%+build%s',
  -- C, C++, C#, Java, Kotlin, Swift, and Dart
  'NOLINT',
  'clang%-format%s',
  'clang%-tidy',
  'IWYU%s+pragma:',
  'cppcheck%-suppress',
  'LCOV_EXCL',
  'GCOVR_EXCL',
  'ReSharper%s',
  '<auto%-generated',
  'CHECKSTYLE:',
  'NOPMD',
  '@formatter:',
  'spotless:',
  'ktlint%-disable',
  'ktlint%-enable',
  'noinspection%s',
  'swiftlint:',
  'swift%-format%-ignore',
  'ignore:%s*%l[%w_]*',
  'ignore_for_file:',
  -- Ruby, PHP, Elixir, and Haskell
  'rubocop:',
  'standard:',
  'steep:',
  'reek:',
  'erb_?lint:',
  ':nocov:',
  'frozen_string_literal:%s*%a+%s*$',
  'typed:%s*%a+%s*$',
  'encoding:%s*[%w_%-]+%s*$',
  'phpcs:',
  '@phpstan%-',
  'phpstan%-ignore',
  '@psalm%-',
  '@codeCoverageIgnore',
  'credo:',
  'HLINT%s',
  -- YAML, TOML, Dockerfile, Terraform and CI
  'yamllint%s',
  'yaml%-language%-server:',
  ':schema%s',
  'taplo:',
  'hadolint%s',
  'checkov:',
  'tfsec:',
  'tflint%-ignore',
  'trivy:',
  'kics%-scan',
  'nosemgrep',
  'renovate:',
  'trunk%-ignore',
  'gitleaks:allow',
  'betterleaks:',
  -- Markdown, HTML, and other spell checkers
  'markdownlint%-disable',
  'markdownlint%-enable',
  'markdownlint%-capture',
  'markdownlint%-restore',
  'markdownlint%-configure%-file',
  'vale%s',
  'textlint%-disable',
  'textlint%-enable',
  'htmlhint%s',
  'djlint:',
  'cspell:',
  'codespell:',
  'typos:',
  -- Any language: editor settings, license headers, and code scanners
  'vim?:%s',
  'ex:%s',
  '%-%*%-',
  'SPDX%-%a[%w%-]*:',
  'REUSE%-Ignore%a+',
  '@generated',
  'NOSONAR',
  'lgtm%s*%[',
  'codeql%[',
}

-- What a comment leader may be: `--`, `#`, `//`, `/*`, `<!--`, `;`, `%` and
-- `"`. It must not follow a letter, a digit, or a backtick, so that neither a
-- hyphenated word nor a directive quoted in prose is taken for one.
local leader = '[<%-#/%*!;%%"]+'

---@type string[]
local directive_patterns = {}
for _, directive in ipairs(directives) do
  local tight = directive:sub(1, 1) == '!'
  local head = tight and directive:sub(2) or directive
  local rest = head:sub(-1) == '$' and '' or '.*'
  table.insert(
    directive_patterns,
    leader .. (tight and '' or '%s*') .. head .. rest
  )
end

-- The span of a `sh-docs` `@option` and its spellings, such as
-- `-l | --loud` or `-v<value> | --value=<value>`, up to the description.
---@param line string
---@return integer? start
---@return integer? finish
local function sh_docs_option(line)
  local s, e = line:find('^%s*#%s*@option')
  if not s then return end
  while true do
    local _, te = line:find('^%s+[%-|]%S*', e + 1)
    if not te then break end
    e = te
  end
  return s, e
end

--- The byte spans of `line` that are directives or tags, not prose
---@param line string
---@return integer[][] spans `{ start, finish }`, 1-based and inclusive
local function directive_spans(line)
  local spans = {}
  for _, pattern in ipairs(tag_patterns) do
    local s, e = line:find(pattern)
    if s then table.insert(spans, { s, e }) end
  end
  local option_start, option_end = sh_docs_option(line)
  if option_start then table.insert(spans, { option_start, option_end }) end
  for _, pattern in ipairs(directive_patterns) do
    local init = 1
    while init <= #line do
      local s, e = line:find(pattern, init)
      if not s then break end
      local in_word = s > 1 and line:sub(s - 1, s - 1):match('[%w_`]')
      if not in_word then table.insert(spans, { s, e }) end
      init = s + 1
    end
  end
  return spans
end

-- The spans of the lines seen lately, by their text. A publish covers the
-- whole buffer, and its lines run through over a hundred patterns each; an
-- edit changes few of them. Dropped whole once full, which keeps it bounded.
---@type table<string, integer[][]>
local spans_of = {}
local spans_count = 0
local SPANS_MAX = 4096

---@param line string
---@param col integer 1-based byte column
---@return boolean
local function in_directive(line, col)
  local spans = spans_of[line]
  if not spans then
    if spans_count >= SPANS_MAX then
      spans_of, spans_count = {}, 0
    end
    spans = directive_spans(line)
    spans_of[line], spans_count = spans, spans_count + 1
  end
  for _, span in ipairs(spans) do
    if col >= span[1] and col <= span[2] then return true end
  end
  return false
end

-- Harper drops a whole `---@type T Description` line, so the `---` line that
-- carries the description on reads to it as a sentence of its own, and its
-- first word as one that should be capitalized. That one complaint is dropped
-- when the description above it has not ended its sentence.
---@param bufnr integer
---@param lnum integer 0-based line of the diagnostic
---@param line string
---@param col integer 1-based byte column
---@return boolean
local function continues_annotation(bufnr, lnum, line, col)
  if line:match('^%s*%-%-%-%s*()') ~= col then return false end
  for prev = lnum - 1, 0, -1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, prev, prev + 1, false)[1]
    if prev == lnum - 1 and text:match('[.!?]%s*$') then return false end
    if text:match('^%s*%-%-%-@%a+%s+%S+%s+%S') then return true end
    if not text:match('^%s*%-%-%-%s*[^%s@|]') then return false end
  end
  return false
end

-- The `sh-docs` tags whose indented lines below hold code or references
-- rather than prose: an `@example` or `@usage` block, and the list under a
-- bare `@see`.
local sh_docs_blocks = { example = true, usage = true, see = true }

-- Whether a line sits inside one of those blocks: walking up through `#`
-- lines that are blank or indented, it reaches one of their tags first.
---@param bufnr integer
---@param lnum integer 0-based line of the diagnostic
---@return boolean
local function in_sh_docs_block(bufnr, lnum)
  for prev = lnum, 0, -1 do
    local text = vim.api.nvim_buf_get_lines(bufnr, prev, prev + 1, false)[1]
    local tag = text:match('^%s*#%s*@(%a+)')
    if tag then return prev < lnum and sh_docs_blocks[tag] == true end
    if not (text:match('^%s*#%s*$') or text:match('^%s*#%s%s+%S')) then
      return false
    end
  end
  return false
end

---@param err? lsp.ResponseError
---@param result lsp.PublishDiagnosticsParams
---@param ctx lsp.HandlerContext
local function publish_diagnostics(err, result, ctx)
  local bufnr = result and vim.uri_to_bufnr(result.uri)
  if bufnr and vim.api.nvim_buf_is_loaded(bufnr) then
    local client = vim.lsp.get_client_by_id(ctx.client_id)
    local encoding = client and client.offset_encoding or 'utf-16'
    result.diagnostics = vim.tbl_filter(function(diagnostic)
      local start = diagnostic.range.start
      local line =
        vim.api.nvim_buf_get_lines(bufnr, start.line, start.line + 1, false)[1]
      if not line then return true end
      local col = (
        vim.str_byteindex(line, encoding, start.character, false) or 0
      ) + 1
      if in_directive(line, col) or in_sh_docs_block(bufnr, start.line) then
        return false
      end
      return not (
        diagnostic.message:find('does not start with a capital letter', 1, true)
        and continues_annotation(bufnr, start.line, line, col)
      )
    end, result.diagnostics)
  end
  return vim.lsp.diagnostic.on_publish_diagnostics(err, result, ctx)
end

---@type vim.lsp.Config
return {
  get_language_id = function(_, filetype)
    return language_ids[filetype] or filetype
  end,
  handlers = {
    ['textDocument/publishDiagnostics'] = publish_diagnostics,
  },
  settings = {
    ['harper-ls'] = {
      -- See `util.harper` for why the dictionary is merged and built once
      userDictPath = require('util.harper').user_dict(),
    },
  },
}
