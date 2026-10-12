--- One language, framework or tool: everything installed and set up for its
--- filetypes. An entry is keyed by its name, which `DyNeo.enabled_languages`
--- and `DyNeo.bundle_languages` list. Two keys are pseudo-languages, never
--- filetypes: `['*']` holds what serves every buffer (its tools come before a
--- language's own, its dial augends join every group), and `['_']` what
--- serves a filetype no language claims.
---@class DyLangSpec
---@field filetypes string[] The filetypes of the language, each claimed by
--- this language alone. Opening one installs everything below, once
--- (`util.lazy_install`). A dialect that reuses another language's parser
--- (`arduino` on `cpp`) lists only its own filetypes.
---@field parser string|DyParserSpec The nvim-treesitter parser, registered
--- for every filetype of the language: a name nvim-treesitter knows, or a
--- `DyParserSpec` for one it does not know or gets from elsewhere.
---@field injected_parsers? string[] Parsers this language's injection
--- queries name outright, nvim-treesitter's as well as the ones in
--- `queries/` and `after/queries/`. An injection whose parser is missing is
--- dropped in silence, and a parser only ever arrives with the filetype that
--- asks for it, so they are installed alongside the language's own. A query
--- that reads its language off the buffer instead -- a Markdown code fence,
--- a D2 block tag -- cannot be served this way and is left alone.
---@field ext? string File extension of the parser's language, when the two
--- differ. `injected` names the scratch file it hands a formatter after the
--- language, and a formatter that switches on the file name (`prettier`,
--- `terraform fmt`, ...) needs the extension it would see on disk.
---@field lsp_servers? (string|DyLspSpec)[] Language servers, by their
--- `vim.lsp.config` name; Mason installs each through mason-lspconfig.
---@field linters? (string|DyLinterSpec)[] nvim-lint linters, by name.
---@field formatters? (string|DyFormatterSpec)[] conform formatters, by name,
--- run in this order. None leaves formatting to the language server.
---@field null_ls? DyNullLsSpec[] none-ls sources: code actions, completion,
--- diagnostics or hover that no server or linter gives.
---@field dap? (string|DyDapSpec)[] Debug adapters, by their nvim-dap name;
--- the configurations themselves live in `lua/plugins/lang/<language>.lua`.
---@field test? string[] The neotest adapters of the language, set up in
--- `lua/plugins/lang/<language>.lua`. `vim-test` among them lets vim-test run
--- the language's files; every other filetype is kept away from it.
---@field neogen? string The annotation convention `<leader>cn` writes. One
--- `util.neogen` builds serves every filetype of the language; one of
--- neogen's own configurations only the filetypes neogen has none for, such
--- as `typescript.tsx`. A language neogen knows needs no entry.
---@field dial? fun(augend: Augend): Augend[] Extra `<C-a>`/`<C-x>` cycles,
--- given `dial.augend`. They form the dial group of the language's name,
--- after the ones of `['*']`.
---@field autopairs? fun(filetypes: string[], rule: Rule, cond: CondOpts, ts_cond: table): Rule[]
--- Extra nvim-autopairs rules, given the language's filetypes and
--- nvim-autopairs' `rule`, `conds` and `ts-conds` modules.
---@field endwise? boolean Close a block with its `end`, `fi` or `done` as
--- it is opened (nvim-treesitter-endwise); the language's grammar must have
--- endwise queries.
---@field otter? boolean Give code embedded in the language's files -- a
--- Markdown fence, say -- the language servers of its own language
--- (otter.nvim), where `DyNeo.enabled_plugins.otter` allows it.

--- A parser nvim-treesitter does not know, or one taken from another
--- repository than its own; set on `User TSUpdate`, before any install.
---@class DyParserSpec
---@field [1] string The parser name, as `vim.treesitter.language` knows it
---@field install_info DyParserInstallSpec

--- Where the parser is built from, handed to nvim-treesitter as it is
---@class DyParserInstallSpec:InstallInfo
---@field url string The repository of the grammar
---@field branch? string A branch other than the repository's default

--- A server with more to say than its name
---@class DyLspSpec
---@field [1] string The `vim.lsp.config` name of the server
---@field enabled? fun(bufnr: integer): boolean Asked for each buffer the
--- server would attach to, so the answer can depend on where that buffer
--- lives rather than on the directory Neovim happened to start in.
---@field filetypes? string[] The filetypes of the language the server is
--- for, when it only suits some of them, as a server for one dialect of YAML
--- does. Every filetype of the language otherwise.

--- A tool answers to three names and they often disagree: `[1]` is the one
--- conform or nvim-lint knows it by, `command` is the binary on `$PATH`, and
--- `mason.package` is what installs it. Only `[1]` is required; the other two
--- are written down whenever they differ, which is why `clang-tidy` appears
--- as `clangtidy` and `erb-formatter` as `erb_format`.
---
--- `command` doubles as the availability probe: a filetype is only given a
--- tool whose command is executable. A formatter that is really a subcommand
--- of a larger binary (`ruff_format` -> `ruff`, `tofu_fmt` -> `tofu`) names
--- that binary, and one that runs inside Neovim itself names `lua`, which
--- `util.languages.is_available` counts as always there.
---
--- A tool Mason has no package for still names a package, one of
--- `tools.mason-registry`. It is built from a release or a language registry
--- where one exists, and otherwise -- a tool that ships with the language's
--- toolchain (`mix`, `zig`, `dart`), with the system (`clang-tidy`), or from a
--- package manager Mason does not speak (CPAN) -- its source is
--- `dytoy:<tool>`, so dytoy installs it the way it does on the rest of the
--- machine.
---
--- `mason.enabled = false` is left for what nothing needs to install: a tool
--- that runs inside Neovim (`lua`) or a command every system has (`sed`,
--- `git`, `curl`).
---
--- `scripts/validate-tools.lua` checks the module and the package of every
--- tool named below, so a name that drifts is caught before it goes silent.

---@class DyLinterSpec
---@field [1] string The nvim-lint name of the linter
---@field opts? table Fields laid over nvim-lint's linter table (`args`,
--- `stdin`, `parser`, ...), for every language that names the linter
---@field command? string The binary, when it is not named `[1]`
---@field mason? DyMasonSpec

---@class DyFormatterSpec
---@field [1] string The conform name of the formatter
---@field filetypes? string[] Only these filetypes of the language
---@field opts? table conform's options of the formatter (`prepend_args`,
--- `condition`, ...). Conform keys them by name alone, so a formatter two
--- languages share has one definition, which reads the buffer if it must.
---@field command? string The binary, when it is not named `[1]`
---@field mason? DyMasonSpec

---@class DyNullLsSpec
---@field [1] string The name of the source
---@field type 'code_actions'|'completion'|'diagnostics'|'formatting'|'hover'
--- The none-ls method, the folder the source lives in
---@field command string The binary the source runs
---@field custom? boolean The source is `lua/tools/<type>/<name>.lua` of
--- this repository rather than a none-ls builtin
---@field remote? boolean Sends the buffer off the machine: never a sensitive one
---@field mason? DyMasonSpec

--- A debug adapter mason-nvim-dap does not map to a package, see `util.dap`
---@class DyDapSpec
---@field [1] string The nvim-dap name of the adapter
---@field mason DyMasonSpec

--- How Mason installs a tool, when its package is not named after the tool
---@class DyMasonSpec
---@field enabled? boolean `false` for a tool nothing has to install
---@field package string The Mason package, in its registry or in
--- `tools.mason-registry`

---@type table<string, {filetypes: string[]}>
local reuse_filetypes = {
  bash = {
    filetypes = {
      'sh',
      'bats',
      'sh.ebuild',
      'sh.install',
      'sh.PKGBUILD',
    },
  },
  yaml = {
    filetypes = {
      'yaml',
      'yaml.gitlab',
      'yaml.gh-action',
      'yaml.az-pl',
      'yaml.docker-compose',
      'yaml.helm-values',
      'yaml.openapi',
    },
  },
  dockerfile = {
    filetypes = { 'dockerfile' },
  },
}
-- Conform's own formatter for treesitter code blocks: it runs inside Neovim,
-- so `lua` stands in for a binary that does not exist.
local injected_formatter =
  { 'injected', command = 'lua', mason = { enabled = false } }
-- `ltcc` sends the comments it checks to a LanguageTool server, by default
-- the public one: `remote` keeps it away from sensitive buffers.
local ltcc_code_action = {
  'ltcc',
  type = 'code_actions',
  command = 'ltcc',
  custom = true,
  remote = true,
}
local ltcc_diagnostics = {
  'ltcc',
  type = 'diagnostics',
  command = 'ltcc',
  custom = true,
  remote = true,
}
local html_beautify_formatter = {
  'html_beautify',
  command = 'js-beautify',
  mason = { package = 'js-beautify' },
}
-- djLint speaks several template dialects and has to be told which one it is
-- looking at; left alone it reformats everything as plain HTML. `conform`
-- keys a tool's options by its name, so the two entries that use it share one
-- definition and read the dialect off the buffer instead of overwriting each
-- other's profile.
local djlint_formatter = {
  'djlint',
  opts = {
    prepend_args = function(_, ctx)
      return {
        '--profile',
        vim.bo[ctx.buf].filetype == 'htmldjango' and 'django' or 'jinja',
      }
    end,
  },
}
-- `javascript`, `typescript` and `tsx` are one toolchain over three grammars.
-- They need an entry each so that a filetype reaches the parser that actually
-- understands it -- and so an injected ```typescript block is not handed to
-- the formatter under a `.js` name -- but nothing else about them differs.
local js_lsp_servers = { 'vtsls', 'harper_ls' }
local js_linters = {
  {
    'biomejs',
    command = 'biome',
    mason = { package = 'biome' },
  },
}
local js_formatters = { 'biome' }
local js_dap = { 'js', 'firefox' }
local js_test = {
  'neotest-jest',
  'neotest-vitest',
  'neotest-playwright',
  'vim-test',
}
local js_dial = function(augend)
  return {
    augend.constant.new({
      elements = { 'let', 'const' },
      word = true,
      cyclic = true,
    }),
  }
end
-- `/* ... */` is one block comment shared by every C-descended syntax, so the
-- rule is written once here and handed to each language that takes it.
local block_comment_autopairs = function(filetypes, rule)
  return {
    -- Add spaces inside a block comment
    -- e.g., /* | */
    rule('/*', '  */', filetypes):set_end_pair_length(3),
  }
end
-- `<!-- ... -->`, which the built-in rule hands to HTML and Markdown only.
local html_comment_autopairs = function(filetypes, rule)
  return {
    -- Add spaces in a comment
    -- e.g., <!-- | -->
    rule('<!--', '  -->', filetypes):set_end_pair_length(4),
  }
end
-- `{{ ... }}` interpolation, borrowed by every template dialect below. The
-- closing `}` is the one the bracket rule has already inserted, so only the
-- inner half of the pair is added here -- the same trick every rule that
-- starts with `{` uses, and the reason they ask for a `}` ahead of the cursor.
local mustache_autopairs = function(filetypes, rule)
  return {
    -- Add spaces in an interpolation
    -- e.g., {{ | }}
    rule('{{', '  }', filetypes):set_end_pair_length(2),
  }
end
-- Jinja, and the dialects that copy its syntax, add statements and comments
-- to that interpolation.
local jinja_autopairs = function(filetypes, rule, cond)
  return vim.list_extend(mustache_autopairs(filetypes, rule), {
    -- Add spaces in a statement
    -- e.g., {% | %}
    rule('{%', '  %', filetypes)
      :with_pair(cond.after_text('}'))
      :set_end_pair_length(2),

    -- Add spaces in a comment
    -- e.g., {# | #}
    rule('{#', '  #', filetypes)
      :with_pair(cond.after_text('}'))
      :set_end_pair_length(2),
  })
end
local js_autopairs = function(filetypes, rule)
  return vim.list_extend(block_comment_autopairs(filetypes, rule), {
    -- Add a body to an arrow function, spacing out an arrow typed right
    -- after `)`
    -- e.g., () => { | }
    rule('=>', ' {  }', filetypes)
      :replace_endpair(function(opts)
        -- `opts.line` does not hold the `>` yet, so this is the character
        -- before the `=`
        if opts.line:sub(opts.col - 2, opts.col - 2) == ')' then
          return '<BS><BS> => {  }'
        end
        return ' {  }'
      end)
      :set_end_pair_length(2),
  })
end

--- Whether `buf` holds plain JSON rather than JSONC or JSON5, whose comments
--- and trailing commas `jq` and `jsonlint` both reject as parse errors
---@param buf integer
---@return boolean
local strict_json = function(buf)
  return not vim.list_contains({ 'jsonc', 'json5' }, vim.bo[buf].filetype)
end

---@alias DyLangRootSpec table<string,DyLangSpec>
---@type DyLangRootSpec

return {
  -- For all filetypes
  ['*'] = {
    filetypes = { '*' },
    parser = nil,
    lsp_servers = {
      {
        'sonarlint',
        enabled = function(bufnr)
          return vim.fn.executable('java') == 1
            and vim.fs.root(bufnr, { 'sonar-project.properties' }) ~= nil
        end,
      },
      'copilot',
      -- Both are handed every buffer, so they are kept to the projects that
      -- asked for them: `typos_lsp` would otherwise take any `Cargo.toml` or
      -- `pyproject.toml` for its root, and `ast_grep` has no rules to report
      -- without an `sgconfig.yml`.
      {
        'typos_lsp',
        enabled = function(bufnr)
          return vim.fs.root(
            bufnr,
            { 'typos.toml', '_typos.toml', '.typos.toml' }
          ) ~= nil
        end,
      },
      {
        'ast_grep',
        enabled = function(bufnr)
          return vim.fs.root(bufnr, { 'sgconfig.yml', 'sgconfig.yaml' }) ~= nil
        end,
      },
    },
    formatters = {
      { 'trim_whitespace', command = 'lua', mason = { enabled = false } },
      { 'trim_newlines', command = 'lua', mason = { enabled = false } },
      {
        'condense_blank_lines',
        command = 'sed',
        mason = { enabled = false },
      },
    },
    linters = {
      'vale',
      -- Reads the buffer from stdin and reports only which rule matched,
      -- never the secret itself, so a leak is flagged before it is saved.
      -- Mason has no package; `tools.mason-registry.betterleaks` adds one.
      'betterleaks',
    },
    null_ls = {
      {
        'dictionary',
        type = 'hover',
        command = 'curl',
        mason = { enabled = false },
      },
      {
        'trail_space',
        type = 'diagnostics',
        command = 'lua',
        mason = { enabled = false },
      },
      {
        'gitsigns',
        type = 'code_actions',
        command = 'git',
        mason = { enabled = false },
      },
      -- Runs inside Neovim, as `trail_space` does; `remote` keeps it off
      -- buffers whose text must stay on the machine
      {
        'ai_fix',
        type = 'code_actions',
        command = 'lua',
        custom = true,
        remote = true,
        mason = { enabled = false },
      },
    },
    dial = function(augend)
      local logical_alias = augend.constant.new({
        elements = { '&&', '||' },
        word = false,
        cyclic = true,
      })

      local ordinal_numbers = augend.constant.new({
        elements = {
          'first',
          'second',
          'third',
          'fourth',
          'fifth',
          'sixth',
          'seventh',
          'eighth',
          'ninth',
          'tenth',
        },
        word = false,
        cyclic = true,
      })

      local months = augend.constant.new({
        elements = {
          'January',
          'February',
          'March',
          'April',
          'May',
          'June',
          'July',
          'August',
          'September',
          'October',
          'November',
          'December',
        },
        word = true,
        cyclic = true,
      })

      local log_level = augend.constant.new({
        elements = { 'trace', 'debug', 'info', 'warn', 'error', 'fatal' },
        word = true,
        cyclic = true,
      })

      local answer = augend.constant.new({
        elements = { 'yes', 'no' },
        word = true,
        cyclic = true,
      })

      return {
        augend.integer.alias.decimal, -- nonnegative decimal number (0, 1, 2, 3, ...)
        augend.integer.alias.decimal_int, -- nonnegative and negative decimal number
        augend.integer.alias.hex, -- nonnegative hex number  (0x01, 0x1a1f, etc.)
        augend.date.alias['%Y/%m/%d'], -- date (2022/02/19, etc.)
        augend.date.alias['%d/%m/%Y'], -- date (19/02/2022, ...)
        augend.constant.alias.bool, -- boolean value (true <-> false)
        augend.constant.alias.Bool, -- boolean value (True <-> False)
        augend.semver.alias.semver, -- semver
        ordinal_numbers,
        augend.constant.alias.en_weekday, -- Mon, Tue, ..., Sat, Sun
        augend.constant.alias.en_weekday_full, -- Monday, Tuesday, ..., Saturday, Sunday
        months,
        logical_alias,
        log_level,
        answer,
      }
    end,
    -- See rules API: https://github.com/windwp/nvim-autopairs/wiki/Rules-API
    autopairs = function(_, rule, cond, _)
      local ignore_filetypes = { 'gitattributes' }
      vim.list_extend(ignore_filetypes, reuse_filetypes.bash.filetypes)
      vim.list_extend(ignore_filetypes, reuse_filetypes.yaml.filetypes)
      vim.list_extend(ignore_filetypes, reuse_filetypes.dockerfile.filetypes)
      local equal_rule_ignored_filetypes = vim.tbl_map(
        function(ft) return '-' .. ft end,
        ignore_filetypes
      )

      return {
        -- Add spaces between parentheses
        rule(' ', ' ')
          :with_pair(cond.done())
          :replace_endpair(function(opts)
            local pair = opts.line:sub(opts.col - 1, opts.col)
            if vim.tbl_contains({ '()', '{}', '[]' }, pair) then
              return ' ' -- it return space here
            end
            return '' -- return empty
          end)
          :with_move(cond.none())
          :with_cr(cond.none())
          :with_del(function(opts)
            local col = vim.api.nvim_win_get_cursor(0)[2]
            local context = opts.line:sub(col - 1, col + 2)
            return vim.tbl_contains({ '(  )', '{  }', '[  ]' }, context)
          end),
        rule('', ' )')
          :with_pair(cond.none())
          :with_move(function(opts) return opts.char == ')' end)
          :with_cr(cond.none())
          :with_del(cond.none())
          :use_key(')'),
        rule('', ' }')
          :with_pair(cond.none())
          :with_move(function(opts) return opts.char == '}' end)
          :with_cr(cond.none())
          :with_del(cond.none())
          :use_key('}'),
        rule('', ' ]')
          :with_pair(cond.none())
          :with_move(function(opts) return opts.char == ']' end)
          :with_cr(cond.none())
          :with_del(cond.none())
          :use_key(']'),

        -- Add space after comma when have following text after comma
        rule(',', ' ')
          :replace_endpair(function(opts)
            local next_char = opts.line:sub(opts.col, opts.col)
            if next_char:match('%w$') then return ' ' end
            return ''
          end)
          :set_end_pair_length(0),

        -- Add space on equal sign
        rule('=', ' ', equal_rule_ignored_filetypes)
          :with_pair(cond.not_inside_quote())
          :with_pair(function(opts)
            local last_char = opts.line:sub(opts.col - 1, opts.col - 1)
            if last_char:match('[%w%=%s]') then return true end
            return false
          end)
          :replace_endpair(function(opts)
            local prev_2char = opts.line:sub(opts.col - 2, opts.col - 1)
            local next_char = opts.line:sub(opts.col, opts.col)
            next_char = next_char == ' ' and '' or ' '
            if prev_2char:match('%w$') then return '<BS> =' .. next_char end
            if prev_2char:match('%=$') then return next_char end
            if prev_2char:match('=') then return '<BS><BS>=' .. next_char end
            return ''
          end)
          :set_end_pair_length(0)
          :with_move(cond.none())
          :with_del(cond.none()),
      }
    end,
  },
  -- Fallback for a filetype left with no tool of that kind: `conform` and
  -- the `nvim-lint` setup in `plugins.executor.linting` reach for it when
  -- the filetype's own list is empty. A tool whose command is not on
  -- `$PATH` is dropped from that list, so a declared language with nothing
  -- installed falls back here too, not only a filetype no entry names. Only `formatters` and `linters` are read;
  -- servers and `null_ls` sources have no such fallback.
  ---@diagnostic disable-next-line: missing-fields
  ['_'] = {
    filetypes = { '_' },
    linters = {
      { 'compiler', command = 'lua', mason = { enabled = false } },
    },
  },

  -- Programming language & Frameworks {
  angular = { -- See `html` and `typescript`
    filetypes = { 'htmlangular' },
    parser = 'angular',
    injected_parsers = { 'css', 'javascript', 'json' },
    ext = 'html',
    lsp_servers = { 'angularls', 'tailwindcss', 'harper_ls' },
    linters = {
      {
        'biomejs',
        command = 'biome',
        mason = { package = 'biome' },
      },
    },
    formatters = { 'biome', html_beautify_formatter },
  },
  arduino = { -- See `cpp`
    filetypes = { 'arduino' },
    parser = 'cpp',
    injected_parsers = { 'doxygen', 'printf', 're2c' },
    lsp_servers = { 'arduino_language_server', 'harper_ls' },
    linters = {
      -- nvim-lint drops the dash from the binary's name, and `clang-tidy`
      -- comes with the system's clang, which dytoy installs.
      { 'clangtidy', command = 'clang-tidy', mason = { package = 'clang' } },
    },
    formatters = { 'clang-format' },
  },
  astro = { -- See `html` and `typescript`
    filetypes = { 'astro' },
    parser = 'astro',
    injected_parsers = { 'css', 'javascript', 'json', 'scss', 'typescript' },
    -- `prettier` needs `prettier-plugin-astro` for a component file, so
    -- formatting is left to the language server.
    lsp_servers = { 'astro', 'tailwindcss', 'harper_ls' },
    linters = js_linters,
  },
  bash = {
    filetypes = reuse_filetypes.bash.filetypes,
    parser = 'bash',
    injected_parsers = { 'awk', 'printf', 'readline' },
    ext = 'sh',
    lsp_servers = {
      'bashls',
      { 'termuxls', filetypes = { 'sh.ebuild', 'sh.install', 'sh.PKGBUILD' } },
      'harper_ls',
    },
    linters = { 'dyshellint' },
    formatters = {
      'shellcheck',
      { 'shfmt', opts = { prepend_args = { '-i', '2', '-ci', '-bn', '-sr' } } },
    },
    null_ls = {
      {
        'shellcheck',
        type = 'code_actions',
        command = 'shellcheck',
        custom = true,
      },
    },
    dap = { 'bash' },
    test = { 'vim-test' },
    neogen = 'sh_docs',
    endwise = true,
  },
  cpp = {
    filetypes = { 'c', 'cpp' },
    parser = 'cpp',
    injected_parsers = { 'doxygen', 'printf', 're2c' },
    -- clang-tidy runs inside clangd (`--clang-tidy`); nvim-lint running it as
    -- well reported every finding twice
    lsp_servers = { 'clangd', 'harper_ls' },
    formatters = { 'clang-format' },
    dap = { 'codelldb' },
    test = { 'neotest-gtest', 'vim-test' },
    autopairs = block_comment_autopairs,
  },
  c_sharp = {
    filetypes = { 'cs' },
    parser = 'c_sharp',
    ext = 'cs',
    lsp_servers = { 'omnisharp', 'harper_ls' },
    formatters = {
      {
        'csharpier',
        command = 'dotnet',
        mason = { package = 'csharpier' },
      },
    },
    dap = { 'coreclr' },
    test = { 'neotest-vstest' },
    autopairs = block_comment_autopairs,
  },
  blade = { -- See `php` and `html`
    filetypes = { 'blade' },
    parser = 'blade',
    injected_parsers = {
      'css',
      'javascript',
      'json',
      'php_only',
      'python',
      'toml',
    },
    lsp_servers = { 'laravel_ls', 'tailwindcss', 'harper_ls' },
    formatters = { 'blade-formatter' },
    autopairs = mustache_autopairs,
    endwise = true,
  },
  clojure = {
    filetypes = { 'clojure' },
    parser = 'clojure',
    ext = 'clj',
    lsp_servers = { 'clojure_lsp', 'harper_ls' },
    linters = { 'clj-kondo' },
    -- `cljstyle` and `zprint` would do as well; `cljfmt` is the one
    -- `clojure_lsp` itself runs, so the server and the formatter agree.
    formatters = { 'cljfmt' },
    test = { 'vim-test' },
  },
  css = {
    filetypes = { 'css', 'less' },
    parser = 'css',
    lsp_servers = { 'tailwindcss' },
    linters = { 'stylelint' },
    formatters = { 'prettier' },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
    },
    dial = function(augend)
      return {
        augend.hexcolor.new({ case = 'lower' }),
        augend.hexcolor.new({ case = 'upper' }),
      }
    end,
    autopairs = block_comment_autopairs,
  },
  cucumber = {
    filetypes = { 'cucumber' },
    parser = {
      'gherkin',
      install_info = {
        url = 'https://github.com/binhtran432k/tree-sitter-gherkin',
        -- nvim-treesitter has no queries for it, so take the grammar's own
        queries = 'queries/gherkin',
      },
    },
    lsp_servers = { 'cucumber_language_server' },
    test = { 'vim-test' },
  },
  dart = {
    filetypes = { 'dart' },
    parser = 'dart',
    -- `dartls` and `dart format` both ship with the SDK, which dytoy installs.
    lsp_servers = { 'dartls', 'harper_ls' },
    formatters = {
      { 'dart_format', command = 'dart', mason = { package = 'dart' } },
    },
    test = { 'neotest-dart' },
    neogen = 'dartdoc',
    autopairs = block_comment_autopairs,
  },
  elixir = {
    filetypes = { 'elixir' },
    parser = 'elixir',
    injected_parsers = { 'eex', 'heex', 'json', 'surface', 'zig' },
    ext = 'exs',
    lsp_servers = { 'elixirls', 'harper_ls' },
    -- `mix credo` and `mix format` are tasks of the Elixir toolchain, which
    -- dytoy installs.
    linters = { { 'credo', command = 'mix', mason = { package = 'elixir' } } },
    formatters = { { 'mix', command = 'mix', mason = { package = 'elixir' } } },
    test = { 'neotest-elixir' },
    neogen = 'exdoc',
    endwise = true,
  },
  erlang = { -- See `elixir`
    filetypes = { 'erlang' },
    parser = 'erlang',
    ext = 'erl',
    -- `elp` is the Erlang Language Platform; `erlang_ls` is the older one and
    -- is not in lspconfig.
    lsp_servers = { 'elp' },
    formatters = { { 'erlfmt', mason = { package = 'erlfmt' } } },
    test = { 'vim-test' },
    autopairs = function(filetypes, rule)
      return {
        -- Close a binary
        -- e.g., <<|>>
        rule('<<', '>>', filetypes),
      }
    end,
    endwise = true,
  },
  fish = {
    filetypes = { 'fish' },
    parser = 'fish',
    lsp_servers = { 'fish_lsp' },
    -- `fish -n` and `fish_indent` are the shell's own, installed by dytoy
    linters = {
      { 'fish', mason = { package = 'fish' } },
    },
    formatters = {
      { 'fish_indent', mason = { package = 'fish' } },
    },
    neogen = 'fishdoc',
    endwise = true,
  },
  gdscript = {
    filetypes = { 'gdscript' },
    parser = 'gdscript',
    ext = 'gd',
    -- Godot serves the language server itself, over a port; Mason has no
    -- package for it.
    lsp_servers = { 'gdscript' },
    formatters = { 'gdscript-formatter' },
  },
  gdshader = { -- See `gdscript`
    filetypes = { 'gdshader' },
    parser = 'gdshader',
    -- No formatter exists; the server is a standalone binary Mason has no
    -- package for.
    lsp_servers = { 'gdshader_lsp' },
    autopairs = block_comment_autopairs,
  },
  gleam = {
    filetypes = { 'gleam' },
    parser = 'gleam',
    -- the `gleam` binary is both the server and the formatter
    lsp_servers = { 'gleam', 'harper_ls' },
    formatters = { { 'gleam', mason = { package = 'gleam' } } },
    test = { 'vim-test' },
    neogen = 'gleamdoc',
  },
  go = {
    filetypes = { 'go' },
    parser = 'go',
    injected_parsers = { 'printf', 're2c' },
    lsp_servers = { 'gopls', 'harper_ls' },
    linters = {
      {
        'golangcilint',
        command = 'golangci-lint',
        mason = { package = 'golangci-lint' },
      },
    },
    formatters = { 'goimports', 'gofumpt' },
    null_ls = {
      { 'gomodifytags', type = 'code_actions', command = 'gomodifytags' },
      { 'impl', type = 'code_actions', command = 'impl' },
    },
    dap = { 'delve' },
    test = { 'neotest-golang' },
    autopairs = block_comment_autopairs,
  },
  graphql = {
    filetypes = { 'graphql' },
    parser = 'graphql',
    lsp_servers = { 'graphql' },
    -- `biome` is this config's JS/TS formatter, but a `.graphql` file is not
    -- part of that toolchain; `prettier` reads it without a plugin, the way
    -- it already does the stylesheets.
    formatters = { 'prettier' },
  },
  handlebars = { -- See `html`
    filetypes = { 'handlebars' },
    parser = 'glimmer',
    injected_parsers = { 'css', 'javascript' },
    ext = 'hbs',
    -- lspconfig hands `ember` TypeScript and JavaScript too, with `.git` for
    -- a root: it would run in every repository once installed
    lsp_servers = {
      { 'ember', filetypes = { 'handlebars' } },
      'tailwindcss',
      'harper_ls',
    },
    autopairs = mustache_autopairs,
    endwise = true,
  },
  haskell = {
    filetypes = { 'haskell' },
    parser = 'haskell',
    injected_parsers = {
      'css',
      'graphql',
      'haskell_persistent',
      'html',
      'javascript',
      'json',
      'python',
      'sql',
      'typescript',
    },
    ext = 'hs',
    lsp_servers = { 'hls', 'harper_ls' },
    linters = { 'hlint' },
    -- `fourmolu` over `ormolu`: same formatter, but it reads a project's
    -- `fourmolu.yaml` instead of imposing one style.
    formatters = { 'fourmolu' },
    test = { 'neotest-haskell' },
    neogen = 'haddock',
    autopairs = function(filetypes, rule, cond)
      return {
        -- Add spaces in a block comment
        -- e.g., {- | -}
        rule('{-', '  -', filetypes)
          :with_pair(cond.after_text('}'))
          :set_end_pair_length(2),
      }
    end,
  },
  heex = { -- See `elixir`
    filetypes = { 'heex' },
    parser = 'heex',
    injected_parsers = { 'elixir' },
    -- A Phoenix template is part of an Elixir project: the same server reads
    -- it and the same `mix format` writes it back.
    lsp_servers = { 'elixirls', 'tailwindcss', 'harper_ls' },
    formatters = { { 'mix', command = 'mix', mason = { package = 'elixir' } } },
    autopairs = function(filetypes, rule)
      return {
        -- Add spaces in an embedded tag
        -- e.g., <% | %>
        rule('<%', '  %>', filetypes):set_end_pair_length(3),
      }
    end,
    endwise = true,
  },
  html = {
    filetypes = { 'html' },
    parser = 'html',
    injected_parsers = { 'css', 'javascript', 'json', 'python', 'toml' },
    lsp_servers = { 'tailwindcss', 'html', 'harper_ls' },
    linters = { 'htmlhint' },
    formatters = { html_beautify_formatter },
  },
  java = {
    filetypes = { 'java' },
    parser = 'java',
    injected_parsers = { 'javadoc', 'printf' },
    lsp_servers = { 'jdtls', 'harper_ls' },
    -- `jdtls` can format, but only after a project is imported and its
    -- settings resolved; a formatter works on the buffer from the start.
    formatters = { 'google-java-format' },
    -- `java-test` is a bundle nvim-jdtls hands jdtls, for the test keys
    dap = { 'javadbg', 'javatest' },
    test = { 'neotest-java' },
    dial = function(augend)
      return {
        augend.constant.new({
          elements = { 'public', 'protected', 'private' },
          word = true,
          cyclic = true,
        }),
      }
    end,
    autopairs = block_comment_autopairs,
  },
  javascript = { -- See `typescript`
    filetypes = { 'javascript', 'javascriptreact', 'javascript.jsx' },
    parser = 'javascript',
    injected_parsers = {
      'angular',
      'css',
      'glimmer',
      'graphql',
      'groq',
      'html',
      'jsdoc',
      'sql',
      'styled',
    },
    ext = 'js',
    lsp_servers = js_lsp_servers,
    linters = js_linters,
    formatters = js_formatters,
    dap = js_dap,
    test = js_test,
    neogen = 'javascriptreact',
    dial = js_dial,
    autopairs = js_autopairs,
  },
  julia = {
    filetypes = { 'julia' },
    parser = 'julia',
    injected_parsers = { 'bash' },
    ext = 'jl',
    -- No formatter here: `JuliaFormatter` is a Julia package, run from
    -- inside a project's own environment rather than as a binary.
    lsp_servers = { 'julials' },
    endwise = true,
  },
  kotlin = {
    filetypes = { 'kotlin' },
    parser = 'kotlin',
    injected_parsers = { 'printf' },
    ext = 'kt',
    lsp_servers = { 'kotlin_language_server', 'harper_ls' },
    -- `ktlint` can format too, but it only knows its own style; `ktfmt`
    -- takes the formatting and `ktlint` is left to report.
    linters = { 'ktlint' },
    formatters = { 'ktfmt' },
    dap = { 'kotlin' },
    test = { 'vim-test' },
    autopairs = block_comment_autopairs,
  },
  latex = {
    filetypes = { 'tex', 'plaintex' },
    parser = 'latex',
    injected_parsers = { 'python' },
    ext = 'tex',
    -- `ltex` is archived; `ltex_plus` is its maintained fork
    lsp_servers = { 'ltex_plus', 'texlab' },
    formatters = { 'tex-fmt' },
    autopairs = function(filetypes, rule, cond)
      return {
        -- Add pair text after \begin
        -- e.g., \begin{environment} ... \end{environment}
        rule('\\begin{', '\\end{', filetypes)
          :replace_endpair(function(opts)
            local line = opts.line
            local col = opts.col
            local from = col - 8
            local to = line:find('}', from)
            if to then
              local env_name = line:sub(from, to)
              return '\\end{' .. env_name .. '}'
            end
            return '\\end{'
          end)
          :set_end_pair_length(5),

        -- Add pair text after \left
        -- e.g., \left( ... \right)
        rule('\\left', '\\right', filetypes):set_end_pair_length(6),

        -- Add pair text after \frac
        -- e.g., \frac{numerator}{denominator}
        rule('\\frac{', '}{', filetypes)
          :set_end_pair_length(2)
          :with_move(function(opts) return opts.char == '}' end),

        -- Close inline math
        -- e.g., $|$
        rule('$', '$', filetypes),

        -- Add pair text after \start...
        -- e.g., \start... ... \stop...
        -- The second argument is the end pair: filetypes are the third
        rule('\\start(%w*) $', '', filetypes)
          :replace_endpair(function(opts)
            local beforeText = string.sub(opts.line, 0, opts.col)
            local _, _, match = beforeText:find('\\start(%w*)')
            if match and #match > 0 then return ' \\stop' .. match end
            return ''
          end)
          :with_move(cond.none())
          :use_key('<space>')
          :use_regex(true),
      }
    end,
  },
  lua = {
    filetypes = { 'lua' },
    parser = 'lua',
    injected_parsers = { 'bash', 'luadoc', 'luap', 'printf' },
    lsp_servers = { 'lua_ls', 'harper_ls' },
    formatters = { 'stylua' },
    -- Neovim plugins and configs test with plenary-busted, not plain busted
    test = { 'neotest-plenary' },
    dial = function(augend)
      return {
        augend.constant.new({
          elements = { 'and', 'or' },
          word = true,
          cyclic = true,
        }),
      }
    end,
    autopairs = function(filetypes, rule, cond)
      return {
        -- Add spaces in a long bracket, for both strings and `--[[` comments
        -- e.g., --[[ | ]]
        rule('[[', '  ]', filetypes)
          :with_pair(cond.after_text(']'))
          :set_end_pair_length(2),
      }
    end,
    endwise = true,
  },
  nu = {
    filetypes = { 'nu' },
    parser = 'nu',
    -- the server ships with nushell itself; Mason builds `nufmt` from git
    lsp_servers = { 'nushell' },
    formatters = { { 'nufmt', mason = { package = 'nufmt' } } },
  },
  ocaml = {
    filetypes = { 'ocaml' },
    parser = 'ocaml',
    ext = 'ml',
    lsp_servers = { 'ocamllsp' },
    formatters = { 'ocamlformat' },
    neogen = 'odoc',
    autopairs = function(filetypes, rule, cond)
      return {
        -- Add spaces in a block comment
        -- e.g., (* | *)
        rule('(*', '  *', filetypes)
          :with_pair(cond.after_text(')'))
          :set_end_pair_length(2),
      }
    end,
    endwise = true,
  },
  perl = {
    filetypes = { 'perl' },
    parser = 'perl',
    injected_parsers = { 'pod' },
    ext = 'pl',
    lsp_servers = { 'perlnavigator' },
    -- both come from CPAN, through the system packages dytoy installs
    linters = { { 'perlcritic', mason = { package = 'perlcritic' } } },
    formatters = { { 'perltidy', mason = { package = 'perltidy' } } },
    dap = { { 'perl', mason = { package = 'perl-debug-adapter' } } },
    test = { 'vim-test' },
    neogen = 'pod',
  },
  php = {
    filetypes = { 'php' },
    parser = 'php',
    injected_parsers = { 'bash', 'html', 'phpdoc' },
    lsp_servers = { 'intelephense', 'harper_ls' },
    linters = { 'phpcs' },
    formatters = {
      {
        'php_cs_fixer',
        command = 'php-cs-fixer',
        mason = { package = 'php-cs-fixer' },
      },
    },
    dap = { 'php' },
    test = { 'neotest-phpunit' },
    autopairs = block_comment_autopairs,
  },
  python = {
    filetypes = { 'python' },
    parser = 'python',
    injected_parsers = { 'printf' },
    ext = 'py',
    -- The `ruff` server publishes ruff's diagnostics itself; running it as a
    -- linter too listed each of them twice
    lsp_servers = { 'pyright', 'ruff', 'harper_ls' },
    formatters = {
      { 'ruff_fix', command = 'ruff' },
      { 'ruff_format', command = 'ruff' },
      { 'ruff_organize_imports', command = 'ruff' },
    },
    dap = { 'python' },
    test = { 'neotest-python' },
    dial = function(augend)
      return {
        augend.constant.new({
          elements = { 'and', 'or' },
          word = true,
          cyclic = true,
        }),
      }
    end,
  },
  -- Markdown with chunks of code that run. quarto-nvim gives the chunks
  -- their servers itself, through otter, so the entry asks for none.
  quarto = {
    filetypes = { 'quarto', 'rmd' },
    parser = 'markdown',
    injected_parsers = { 'markdown_inline', 'yaml' },
    ext = 'qmd',
  },
  qml = { -- Qt
    filetypes = { 'qml' },
    parser = 'qmljs',
    injected_parsers = {
      'angular',
      'css',
      'glimmer',
      'graphql',
      'groq',
      'html',
      'jsdoc',
      'sql',
      'styled',
    },
    ext = 'qml',
    lsp_servers = { 'qmlls' },
    -- `qmlformat` comes with the Qt tooling, which dytoy installs
    formatters = { { 'qmlformat', mason = { package = 'qmlformat' } } },
    autopairs = block_comment_autopairs,
  },
  r = {
    filetypes = { 'r' },
    parser = 'r',
    ext = 'R',
    lsp_servers = { 'r_language_server' },
    -- `styler` is an R package and needs an R session to run; `air` is a
    -- standalone binary, so Mason can install it like any other tool.
    formatters = { 'air' },
    test = { 'neotest-testthat' },
    neogen = 'roxygen2',
  },
  rails = { -- See `ruby` and `html`
    filetypes = { 'eruby' },
    parser = 'embedded_template',
    injected_parsers = { 'html', 'ruby' },
    ext = 'erb',
    lsp_servers = { 'ruby_lsp', 'tailwindcss', 'harper_ls' },
    linters = {
      { 'erb_lint', command = 'erb-lint', mason = { package = 'erb-lint' } },
    },
    formatters = {
      {
        -- `erb-formatter` the package installs `erb-format` the binary, and
        -- conform knows it under that second name again.
        'erb_format',
        command = 'erb-format',
        mason = { package = 'erb-formatter' },
      },
      html_beautify_formatter,
    },
    autopairs = function(filetypes, rule)
      return {
        -- Add spaces in an embedded tag
        -- e.g., <% | %>
        rule('<%', '  %>', filetypes):set_end_pair_length(3),
      }
    end,
    endwise = true,
  },
  ruby = {
    filetypes = { 'ruby' },
    parser = 'ruby',
    injected_parsers = { 'rbs' },
    ext = 'rb',
    lsp_servers = { 'ruby_lsp', 'harper_ls' },
    linters = { 'rubocop' },
    formatters = { 'rubocop' },
    -- nvim-dap-ruby brings the adapter; `rdbg` is the debugger it runs
    dap = { { 'ruby', mason = { package = 'rdbg' } } },
    test = { 'neotest-rspec', 'vim-test' },
    endwise = true,
  },
  rust = {
    filetypes = { 'rust' },
    parser = 'rust',
    injected_parsers = { 're2c', 'slint' },
    ext = 'rs',
    lsp_servers = { 'rust_analyzer', 'harper_ls' },
    -- `rustfmt` comes with the toolchain, which dytoy installs through mise.
    formatters = { { 'rustfmt', mason = { package = 'rust' } } },
    dap = { 'codelldb' },
    -- `rustaceanvim` serves the neotest adapter, from `cargo test` or nextest
    test = { 'rustaceanvim.neotest' },
    autopairs = function(filetypes, rule)
      return vim.list_extend(block_comment_autopairs(filetypes, rule), {
        -- Close a raw string literal, which the plain quote rule cannot see
        -- e.g., r#"|"#
        rule('r#"', '"#', filetypes),
      })
    end,
  },
  sass = {
    filetypes = { 'scss', 'sass' },
    parser = 'scss',
    lsp_servers = { 'tailwindcss' },
    linters = { 'stylelint' },
    -- Prettier has no parser for the indented `.sass` syntax
    formatters = { { 'prettier', filetypes = { 'scss' } } },
    dial = function(augend)
      return {
        augend.hexcolor.new({ case = 'lower' }),
        augend.hexcolor.new({ case = 'upper' }),
      }
    end,
    autopairs = block_comment_autopairs,
  },
  scala = {
    filetypes = { 'scala' },
    parser = 'scala',
    -- `metals` bootstraps itself.
    lsp_servers = { 'metals', 'harper_ls' },
    formatters = { { 'scalafmt', mason = { package = 'scalafmt' } } },
    test = { 'vim-test' },
    neogen = 'scaladoc',
    autopairs = block_comment_autopairs,
  },
  snakemake = {
    filetypes = { 'snakemake' },
    parser = 'snakemake',
  },
  solidity = {
    filetypes = { 'solidity' },
    parser = 'solidity',
    injected_parsers = { 'doxygen' },
    ext = 'sol',
    lsp_servers = { 'solang', 'harper_ls' },
    formatters = {
      { 'forge_fmt', command = 'forge', mason = { package = 'foundry' } },
    },
    autopairs = block_comment_autopairs,
  },
  sql = {
    filetypes = { 'sql', 'mysql', 'plsql' },
    parser = 'sql',
    linters = { 'sqlfluff' },
    formatters = {
      {
        'sqlfluff',
        opts = {
          -- A dialect on the command line beats the project's own `.sqlfluff`,
          -- which the linter reads: given only when there is none
          args = function(_, ctx)
            if vim.fs.root(ctx.dirname, '.sqlfluff') then
              return { 'format', '-' }
            end
            local dialects = { mysql = 'mysql', plsql = 'oracle' }
            local dialect = dialects[vim.bo[ctx.buf].filetype] or 'ansi'
            return { 'format', '--dialect=' .. dialect, '-' }
          end,
        },
      },
    },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
    },
    endwise = true,
  },
  svelte = { -- See `typescript`
    filetypes = { 'svelte' },
    parser = 'svelte',
    injected_parsers = {
      'css',
      'javascript',
      'json',
      'pug',
      'scss',
      'typescript',
    },
    -- `prettier` needs `prettier-plugin-svelte` for a single-file component,
    -- so formatting is left to the language server.
    lsp_servers = { 'svelte', 'tailwindcss', 'harper_ls' },
    linters = js_linters,
  },
  swift = {
    filetypes = { 'swift' },
    parser = 'swift',
    -- `sourcekit-lsp` ships with the Swift toolchain, Mason has no package.
    lsp_servers = { 'sourcekit', 'harper_ls' },
    linters = { 'swiftlint' },
    formatters = { 'swiftformat' },
    test = { 'vim-test' },
    neogen = 'docc',
    autopairs = block_comment_autopairs,
  },
  templ = { -- See `go` and `html`
    filetypes = { 'templ' },
    parser = 'templ',
    injected_parsers = { 'css', 'javascript', 'printf', 're2c' },
    -- one `templ` binary again: `templ lsp` and `templ fmt`
    lsp_servers = { 'templ', 'tailwindcss', 'harper_ls' },
    formatters = { 'templ' },
    autopairs = function(filetypes, rule)
      return vim.list_extend(
        block_comment_autopairs(filetypes, rule),
        html_comment_autopairs(filetypes, rule)
      )
    end,
  },
  tsx = { -- See `typescript`
    filetypes = { 'typescriptreact', 'typescript.tsx' },
    parser = 'tsx',
    injected_parsers = {
      'angular',
      'css',
      'glimmer',
      'graphql',
      'groq',
      'html',
      'jsdoc',
      'sql',
      'styled',
    },
    lsp_servers = js_lsp_servers,
    linters = js_linters,
    formatters = js_formatters,
    dap = js_dap,
    test = js_test,
    neogen = 'typescriptreact',
    dial = js_dial,
    autopairs = js_autopairs,
  },
  twig = { -- Symfony
    filetypes = { 'twig' },
    parser = 'twig',
    injected_parsers = { 'html' },
    lsp_servers = { 'twiggy_language_server', 'harper_ls' },
    -- Two tools with one purpose between them: `twigcs` only reports and
    -- `twig-cs-fixer` only rewrites.
    linters = { 'twigcs' },
    formatters = { 'twig-cs-fixer' },
    autopairs = jinja_autopairs,
    endwise = true,
  },
  typescript = {
    filetypes = { 'typescript' },
    parser = 'typescript',
    injected_parsers = {
      'angular',
      'css',
      'glimmer',
      'graphql',
      'groq',
      'html',
      'jsdoc',
      'sql',
      'styled',
    },
    ext = 'ts',
    lsp_servers = js_lsp_servers,
    linters = js_linters,
    formatters = js_formatters,
    dap = js_dap,
    test = js_test,
    dial = js_dial,
    autopairs = js_autopairs,
  },
  typst = {
    filetypes = { 'typst' },
    parser = 'typst',
    ext = 'typ',
    lsp_servers = { 'tinymist', 'harper_ls' },
    formatters = { 'typstyle' },
    autopairs = function(filetypes, rule)
      return vim.list_extend(block_comment_autopairs(filetypes, rule), {
        -- Close inline math
        -- e.g., $|$
        rule('$', '$', filetypes),
      })
    end,
  },
  vim = {
    filetypes = { 'vim' },
    parser = 'vim',
    injected_parsers = { 'python', 'ruby' },
    lsp_servers = { 'vimls' },
    linters = { 'vint' },
    endwise = true,
    -- `lua << EOF` blocks
    otter = true,
  },
  vue = { -- See `html` and `typescript`
    filetypes = { 'vue' },
    parser = 'vue',
    injected_parsers = {
      'css',
      'javascript',
      'json',
      'pug',
      'scss',
      'tsx',
      'typescript',
    },
    lsp_servers = { 'vue_ls', 'vtsls', 'tailwindcss', 'harper_ls' },
    -- `biome` cannot read a single-file component, so a Vue file goes to
    -- `prettier` the way the stylesheets already do.
    formatters = { 'prettier' },
    dial = function(augend)
      return {
        augend.constant.new({
          elements = { 'let', 'const' },
          word = true,
          cyclic = true,
        }),
        augend.hexcolor.new({
          case = 'lower',
        }),
        augend.hexcolor.new({
          case = 'upper',
        }),
      }
    end,
    autopairs = mustache_autopairs,
  },
  zig = {
    filetypes = { 'zig' },
    parser = 'zig',
    lsp_servers = { 'zls', 'harper_ls' },
    formatters = {
      { 'zigfmt', command = 'zig', mason = { package = 'zig' } },
    },
    dap = { 'codelldb' },
    test = { 'neotest-zig' },
    neogen = 'zigdoc',
    autopairs = block_comment_autopairs,
  },
  zsh = { -- See `bash`
    filetypes = { 'zsh' },
    parser = 'zsh',
    injected_parsers = { 'printf', 'readline' },
    lsp_servers = { 'harper_ls' },
    -- `shellcheck` and `shfmt` are for POSIX shells and bash, not for zsh;
    -- the linter is `zsh -n` and `beautysh` is what knows the syntax.
    linters = { { 'zsh', mason = { package = 'zsh' } } },
    formatters = { 'beautysh' },
    neogen = 'sh_docs',
    endwise = true,
  },
  ------------------------------------ }

  -- Tools & Markup {
  ansible = { -- See `yaml`
    filetypes = { 'yaml.ansible' },
    parser = 'yaml',
    injected_parsers = { 'bash', 'promql' },
    lsp_servers = { 'ansiblels' },
    linters = {
      {
        -- nvim-lint spells the linter with an underscore while the binary
        -- and the package keep the dash.
        'ansible_lint',
        command = 'ansible-lint',
        mason = { package = 'ansible-lint' },
      },
      -- No `yamllint`: ansible-lint runs it already, as its `yaml` rule
    },
    formatters = {
      'yamlfmt',
    },
    -- A playbook is YAML on disk, so `ltcc` reads it the same way it reads
    -- the rest of them.
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
    },
  },
  awk = {
    filetypes = { 'awk' },
    parser = 'awk',
    injected_parsers = { 'printf' },
    lsp_servers = { 'awk_ls' },
    linters = {
      { 'gawk', mason = { package = 'gawk' } },
    },
    formatters = {
      { 'gawk', mason = { package = 'gawk' } },
    },
  },
  beancount = {
    filetypes = { 'beancount' },
    parser = 'beancount',
    lsp_servers = { 'beancount' },
    linters = {
      {
        'bean_check',
        command = 'bean-check',
        mason = { package = 'beancount' },
      },
    },
    formatters = {
      { 'bean-format', mason = { package = 'beancount' } },
    },
  },
  bicep = {
    filetypes = { 'bicep', 'bicep-params' },
    parser = 'bicep',
    lsp_servers = { 'bicep' },
    formatters = {
      { 'bicep', mason = { package = 'bicep' } },
    },
  },
  cmake = {
    filetypes = { 'cmake' },
    parser = 'cmake',
    lsp_servers = { 'neocmake', 'harper_ls' },
    linters = { 'cmakelint' },
    formatters = {
      {
        'cmake_format',
        command = 'cmake-format',
        mason = { package = 'cmakelang' },
      },
    },
    endwise = true,
  },
  csv = {
    filetypes = { 'csv' },
    parser = 'csv',
  },
  tsv = { -- See `csv`
    filetypes = { 'tsv' },
    parser = 'tsv',
  },
  psv = { -- See `csv`
    filetypes = { 'psv' },
    parser = 'psv',
  },
  d2 = {
    filetypes = { 'd2' },
    parser = {
      'd2',
      install_info = {
        url = 'https://github.com/madmaxieee/tree-sitter-d2',
      },
    },
    injected_parsers = { 'javascript', 'typescript' },
    linters = { 'd2' },
    formatters = { 'd2' },
  },
  cue = {
    filetypes = { 'cue' },
    parser = 'cue',
    -- One binary wearing three hats: `cue lsp`, `cue vet`, `cue fmt`. The
    -- Mason package is the binary, hence the same name three times.
    lsp_servers = { 'cue' },
    linters = { 'cue' },
    formatters = { { 'cue_fmt', command = 'cue', mason = { package = 'cue' } } },
  },
  dbml = {
    filetypes = { 'dbml' },
    parser = {
      'dbml',
      install_info = {
        url = 'https://github.com/dynamotn/tree-sitter-dbml',
      },
    },
  },
  dockerfile = {
    filetypes = reuse_filetypes.dockerfile.filetypes,
    parser = 'dockerfile',
    injected_parsers = { 'bash' },
    lsp_servers = { 'dockerls' },
    linters = { 'hadolint', 'checkov' },
    formatters = { 'dockerfmt' },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
    },
  },
  gitcommit = {
    filetypes = { 'gitcommit' },
    parser = 'gitcommit',
    injected_parsers = { 'git_rebase' },
    lsp_servers = { 'harper_ls' },
    linters = { 'gitlint' },
    -- `remote`: each word typed is a query to the Jira host
    null_ls = {
      {
        'jira',
        type = 'completion',
        command = 'jira',
        custom = true,
        remote = true,
      },
    },
  },
  gitrebase = {
    filetypes = { 'gitrebase' },
    parser = 'git_rebase',
    injected_parsers = { 'bash' },
    null_ls = {
      {
        'gitrebase',
        type = 'code_actions',
        command = 'git',
        mason = { enabled = false },
      },
    },
  },
  gomod = {
    filetypes = { 'gomod' },
    parser = 'gomod',
  },
  gosum = {
    filetypes = { 'gosum' },
    parser = 'gosum',
  },
  gotmpl = {
    filetypes = { 'gotmpl' },
    parser = 'gotmpl',
    injected_parsers = {
      'bash',
      'fish',
      'html',
      'ini',
      'javascript',
      'printf',
      'python',
      'toml',
      'yaml',
    },
    formatters = {
      injected_formatter,
    },
    autopairs = function(filetypes, rule)
      return {
        -- Add spaces in an action, and expand `{-` and `{/` into one that
        -- trims the whitespace before it, the second holding a comment
        -- e.g., {{ | }}, {{- | }}, {{- /* | */ }}
        rule('{{', '  }', filetypes):set_end_pair_length(2),
        rule('{-', '{-  }', filetypes)
          :replace_endpair(function(_) return '<BS><BS>{{-  }' end)
          :set_end_pair_length(2),
        rule('{/', '{/  }', filetypes)
          :replace_endpair(function(_) return '<BS><BS>{{- /*  */ }' end)
          :set_end_pair_length(5),
      }
    end,
    endwise = true,
  },
  gowork = {
    filetypes = { 'gowork' },
    parser = 'gowork',
  },
  groovy = {
    filetypes = { 'groovy' },
    parser = 'groovy',
    lsp_servers = { 'groovyls', 'harper_ls' },
    linters = { 'npm-groovy-lint' },
    formatters = { 'npm-groovy-lint' },
    test = { 'vim-test' },
  },
  helm = { -- See `gotmpl`
    filetypes = { 'helm' },
    parser = 'helm',
    injected_parsers = { 'html', 'javascript', 'json', 'printf', 'yaml' },
    lsp_servers = { 'helm_ls' },
    linters = { 'trivy' },
    formatters = {
      injected_formatter,
    },
    autopairs = function(filetypes, rule)
      return {
        -- Add spaces in an action, and expand `{-` into one that trims the
        -- whitespace before it
        -- e.g., {{ | }}, {{- | }}
        rule('{{', '  }', filetypes):set_end_pair_length(2),
        rule('{-', '{-  }', filetypes)
          :replace_endpair(function(_) return '<BS><BS>{{-  }' end)
          :set_end_pair_length(2),
      }
    end,
    endwise = true,
  },
  htmldjango = { -- See `python` and `html`
    -- Neovim leaves a Django template as `html`, so the extension and the
    -- conventional `templates/` directory are registered in
    -- `ftdetect/filetype.lua`.
    filetypes = { 'htmldjango' },
    parser = 'htmldjango',
    injected_parsers = { 'html' },
    -- lspconfig hands `djlsp` every `html` buffer as well
    lsp_servers = {
      { 'djlsp', filetypes = { 'htmldjango' } },
      'tailwindcss',
      'harper_ls',
    },
    formatters = { djlint_formatter },
    autopairs = function(filetypes, rule, cond)
      return vim.list_extend(
        jinja_autopairs(filetypes, rule, cond),
        html_comment_autopairs(filetypes, rule)
      )
    end,
    endwise = true,
  },
  http = {
    filetypes = { 'http' },
    -- No parser here on purpose: `kulala.nvim` ships its own `kulala_http`
    -- grammar and registers it for this filetype, so claiming the filetype
    -- again would leave the winner up to load order.
    parser = nil,
    lsp_servers = { 'kulala_ls' },
    formatters = { 'kulala-fmt' },
    autopairs = mustache_autopairs,
  },
  hurl = { -- See `http`
    filetypes = { 'hurl' },
    parser = 'hurl',
    injected_parsers = { 'json', 'xml' },
    -- `hurlfmt` is part of the `hurl` release
    formatters = { { 'hurlfmt', mason = { package = 'hurl' } } },
    autopairs = mustache_autopairs,
  },
  hyprlang = {
    filetypes = { 'hyprlang' },
    parser = 'hyprlang',
    injected_parsers = { 'bash' },
    lsp_servers = { 'hyprls' },
  },
  ini = {
    filetypes = { 'ini', 'dosini' },
    parser = 'ini',
  },
  jinja = {
    -- Neovim detects none of the Jinja extensions, and `jinja-lsp` says so
    -- itself: they are registered in `ftdetect/filetype.lua`.
    filetypes = { 'jinja' },
    parser = 'jinja',
    injected_parsers = { 'jinja_inline' },
    ext = 'j2',
    lsp_servers = { 'jinja_lsp', 'harper_ls' },
    formatters = { djlint_formatter },
    autopairs = jinja_autopairs,
    endwise = true,
  },
  jq = {
    filetypes = { 'jq' },
    parser = 'jq',
    -- The `jq` linter and formatter read their input as JSON data, not as a
    -- filter: every `.jq` file was a parse error. The server checks it.
    lsp_servers = { 'jqls' },
  },
  json = {
    filetypes = { 'json', 'jsonc', 'json5', 'json.openapi' },
    parser = 'json5',
    lsp_servers = {
      -- JSON and JSONC only: it flags comments, trailing commas and bare keys
      -- in JSON5 as errors.
      { 'jsonls', filetypes = { 'json', 'jsonc', 'json.openapi' } },
      { 'vacuum', filetypes = { 'json.openapi' } },
    },
    linters = {
      -- nvim-lint asks the condition about the current buffer
      {
        'jsonlint',
        opts = { condition = function() return strict_json(0) end },
      },
      'trivy',
    },
    formatters = {
      {
        'jq',
        opts = {
          condition = function(_, ctx) return strict_json(ctx.buf) end,
        },
      },
    },
  },
  -- One JSON value per line. The `json` grammar reads several values where
  -- `json5` stops at the first, and nothing formats it: `jq` would spread
  -- each value over many lines.
  jsonl = {
    filetypes = { 'jsonl' },
    parser = 'json',
  },
  jsonnet = {
    filetypes = { 'jsonnet' },
    parser = 'jsonnet',
    lsp_servers = { 'jsonnet_ls' },
    formatters = { 'jsonnetfmt' },
  },
  jupyter = {
    filetypes = { 'ipynb' },
    parser = 'json',
    formatters = {
      {
        -- `jupytext` converts, it does not format, so conform ships no
        -- definition for it. `--pipe` is what makes it useful here: it runs a
        -- real formatter over the code cells and writes the notebook back
        -- with its outputs, execution counts and markdown cells untouched. A
        -- notebook then gets the same `ruff format` a `.py` buffer does.
        'jupytext',
        opts = {
          command = 'jupytext',
          args = {
            '--from',
            'ipynb',
            '--to',
            'ipynb',
            '--pipe',
            'ruff format -',
            '-',
          },
        },
      },
    },
  },
  just = {
    filetypes = { 'just' },
    parser = 'just',
    injected_parsers = { 'bash', 'javascript', 'python' },
    lsp_servers = { 'just' },
    -- `just --fmt` is the tool itself
    formatters = { { 'just', mason = { package = 'just' } } },
    -- Recipe bodies
    otter = true,
  },
  kdl = {
    filetypes = { 'kdl' },
    parser = 'kdl',
    -- what zellij's configuration is written in; Mason has the formatter but
    -- no package for the server
    lsp_servers = { 'kdl_lsp' },
    formatters = { 'kdlfmt' },
    autopairs = block_comment_autopairs,
  },
  make = {
    filetypes = { 'config', 'automake', 'make' },
    parser = 'make',
    injected_parsers = { 'bash' },
    lsp_servers = { 'autotools_ls' },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
    },
    endwise = true,
  },
  markdown = {
    filetypes = { 'markdown', 'markdown.mdx' },
    parser = 'markdown',
    injected_parsers = { 'html', 'markdown_inline', 'toml', 'yaml' },
    ext = 'md',
    lsp_servers = { 'marksman', 'harper_ls' },
    linters = { 'markdownlint-cli2' },
    formatters = {
      injected_formatter,
      {
        'markdown-toc',
        opts = {
          condition = function(_, ctx)
            for _, line in
              ipairs(vim.api.nvim_buf_get_lines(ctx.buf, 0, -1, false))
            do
              if line:find('<!%-%- toc %-%->') then return true end
            end
          end,
        },
      },
      {
        'markdownlint-cli2',
        opts = {
          condition = function(_, ctx)
            local diag = vim.tbl_filter(
              function(d) return d.source == 'markdownlint' end,
              vim.diagnostic.get(ctx.buf)
            )
            return #diag > 0
          end,
        },
      },
    },
    dial = function(augend)
      return {
        augend.constant.new({
          elements = { '[ ]', '[x]' },
          word = false,
          cyclic = true,
        }),
        augend.misc.alias.markdown_header,
      }
    end,
    otter = true,
  },
  mermaid = {
    -- No server and no formatter exist for it; the parser is what makes a
    -- diagram readable, in its own file and inside a markdown fence.
    filetypes = { 'mermaid' },
    parser = 'mermaid',
    endwise = true,
  },
  -- Groovy with processes and channels: there is no grammar of Nextflow's
  -- own, and the Groovy one reads its pipelines and its `nextflow.config`
  -- but for the commas of a declaration such as `tuple val(x), path(y)`
  nextflow = {
    filetypes = { 'nextflow' },
    parser = 'groovy',
    ext = 'nf',
  },
  nginx = {
    filetypes = { 'nginx' },
    parser = 'nginx',
    lsp_servers = { 'nginx_language_server' },
    formatters = {
      { 'nginxfmt', mason = { package = 'nginx-config-formatter' } },
    },
  },
  nix = {
    filetypes = { 'nix' },
    parser = 'nix',
    injected_parsers = {
      'bash',
      'fish',
      'haskell',
      'javascript',
      'perl',
      'python',
      'rust',
    },
    lsp_servers = { 'nil_ls', 'harper_ls' },
    linters = {
      { 'nix', command = 'nix', mason = { package = 'nix' } },
      { 'statix', command = 'statix', mason = { package = 'statix' } },
    },
    formatters = { 'nixfmt' },
    null_ls = {
      { 'statix', type = 'code_actions', command = 'statix' },
    },
  },
  prisma = {
    filetypes = { 'prisma' },
    parser = 'prisma',
    -- the server formats
    lsp_servers = { 'prismals' },
    linters = { { 'prisma-lint', mason = { package = 'prisma-lint' } } },
  },
  promql = {
    filetypes = { 'promql' },
    parser = 'promql',
    lsp_servers = { 'promqlls' },
  },
  proto = {
    filetypes = { 'proto' },
    parser = 'proto',
    lsp_servers = { 'buf_ls' },
    linters = {
      { 'buf_lint', command = 'buf', mason = { package = 'buf' } },
    },
    formatters = {
      { 'buf', mason = { package = 'buf' } },
    },
    autopairs = block_comment_autopairs,
  },
  rego = {
    filetypes = { 'rego' },
    parser = 'rego',
    lsp_servers = { 'regal' },
    linters = {
      { 'opa_check', command = 'opa', mason = { package = 'opa' } },
    },
    formatters = {
      { 'opa_fmt', command = 'opa', mason = { package = 'opa' } },
    },
    null_ls = {
      { 'regal', type = 'code_actions', command = 'regal' },
    },
  },
  systemd = {
    filetypes = { 'systemd' },
    parser = nil,
    lsp_servers = { 'systemd_lsp' },
  },
  terraform = {
    filetypes = { 'tf', 'terraform', 'terraform-vars' },
    parser = 'terraform',
    ext = 'tf',
    lsp_servers = { 'terraformls' },
    linters = { 'tflint', 'trivy', 'checkov' },
    formatters = {
      { 'tofu_fmt', command = 'tofu', mason = { package = 'opentofu' } },
    },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
      {
        'opentofu_validate',
        type = 'diagnostics',
        command = 'tofu',
        mason = { package = 'opentofu' },
      },
    },
  },
  terragrunt = {
    filetypes = { 'terragrunt' },
    parser = 'hcl',
    lsp_servers = { 'terragruntls' },
    formatters = {
      {
        'terragrunt_hclfmt',
        command = 'terragrunt',
        mason = { package = 'terragrunt' },
      },
    },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
      {
        'terragrunt_validate',
        type = 'diagnostics',
        command = 'terragrunt',
        mason = { package = 'terragrunt' },
        custom = true,
      },
    },
  },
  toml = {
    filetypes = { 'toml' },
    parser = 'toml',
    injected_parsers = { 'bash' },
    lsp_servers = { 'taplo', 'harper_ls' },
    formatters = {
      'taplo',
      injected_formatter,
    },
    otter = true,
  },
  treesitter = {
    filetypes = { 'query' },
    parser = 'query',
    injected_parsers = { 'luap' },
    ext = 'scm',
    lsp_servers = { 'ts_query_ls' },
    formatters = {
      { 'format-queries', command = 'lua', mason = { enabled = false } },
    },
  },
  xml = {
    filetypes = { 'xml', 'svg', 'xsd', 'xslt' },
    parser = 'xml',
    injected_parsers = { 'css', 'javascript', 'sql' },
    lsp_servers = { 'lemminx' },
    formatters = {
      {
        -- The package is `xmlformatter`, the binary it installs is
        -- `xmlformat`, and conform knows it by the package's name again.
        'xmlformatter',
        command = 'xmlformat',
        mason = { package = 'xmlformatter' },
      },
    },
    autopairs = html_comment_autopairs,
  },
  yaml = {
    filetypes = reuse_filetypes.yaml.filetypes,
    parser = 'yaml',
    -- `queries/yaml/injections.scm` hands every CI script to `bash` and
    -- every Prometheus `expr:` to `promql`.
    injected_parsers = { 'bash', 'promql' },
    lsp_servers = {
      'yamlls',
      { 'gitlab_ci_ls', filetypes = { 'yaml.gitlab' } },
      { 'gh_actions_ls', filetypes = { 'yaml.gh-action' } },
      { 'azure_pipelines_ls', filetypes = { 'yaml.az-pl' } },
      {
        'docker_compose_language_service',
        filetypes = { 'yaml.docker-compose' },
      },
      { 'helm_ls', filetypes = { 'yaml.helm-values' } },
      { 'vacuum', filetypes = { 'yaml.openapi' } },
    },
    -- Policy checks of a Kubernetes manifest (`checkov`, `kube_linter`, and
    -- `conftest` where the project keeps a `policy/` directory) decide in
    -- their own `condition`, see `lua/lint/linters/`
    linters = {
      'yamllint',
      'trivy',
      'checkov',
      {
        'kube_linter',
        command = 'kube-linter',
        mason = { package = 'kube-linter' },
      },
      'conftest',
      {
        'actionlint',
        opts = {
          condition = function() return vim.bo.filetype == 'yaml.gh-action' end,
        },
      },
      -- The security of a workflow: unpinned actions, template injection,
      -- credentials left to the checkout. Offline: a lint on every save
      -- asks GitHub nothing
      {
        'zizmor',
        opts = {
          condition = function() return vim.bo.filetype == 'yaml.gh-action' end,
          prepend_args = { '--offline' },
        },
      },
    },
    formatters = {
      'yamlfmt',
      injected_formatter,
    },
    null_ls = {
      ltcc_code_action,
      ltcc_diagnostics,
    },
    -- CI and Taskfile scripts: `run`, `script`, `cmds`, ...
    otter = true,
  },
  yuck = {
    filetypes = { 'yuck' },
    parser = 'yuck',
    injected_parsers = { 'jq' },
  },
  ----------------- }
}
