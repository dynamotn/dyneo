return {
  {
    -- Formatters
    'stevearc/conform.nvim',
    dependencies = { 'mason.nvim' },
    cmd = 'ConformInfo',
    keys = {
      {
        '<leader>cF',
        function()
          -- Injected code goes to formatters that load the project's code
          if require('util.untrusted').held(0) then return end
          require('conform').format({
            formatters = { 'injected' },
            timeout_ms = 3000,
          })
        end,
        mode = { 'n', 'x' },
        desc = 'Format Injected Langs',
      },
    },
    init = function()
      -- Format through conform first, with the LSP as the fallback
      require('util.plugin').on_very_lazy(function()
        require('util.format').register({
          name = 'conform.nvim',
          priority = 100,
          primary = true,
          format = function(buf) require('conform').format({ bufnr = buf }) end,
          sources = function(buf)
            return vim.tbl_map(
              function(v) return v.name end,
              require('conform').list_formatters(buf)
            )
          end,
        })
      end)
    end,
    ---@param opts conform.setupOpts
    opts = function(_, opts)
      opts = vim.tbl_deep_extend('keep', opts, {
        default_format_opts = {
          timeout_ms = 3000,
          -- `util.format` relies on these
          async = false,
          quiet = false,
          lsp_format = 'fallback',
        },
        formatters_by_ft = {
          lua = { 'stylua' },
          fish = { 'fish_indent' },
          sh = { 'shfmt' },
        },
        formatters = {
          injected = { options = { ignore_errors = true } },
        },
      })
      -- In Lua: a sed script that joins lines is written differently for GNU
      -- and BSD sed, and macOS has the latter
      opts.formatters.condense_blank_lines = {
        format = function(_, _, lines, callback)
          local out, blank = {}, false
          for _, line in ipairs(lines) do
            if not (blank and line == '') then table.insert(out, line) end
            blank = line == ''
          end
          callback(nil, out)
        end,
      }

      local languages = require('config.languages')
      -- `pairs` walks the languages in whatever order it likes, and several of
      -- them meet on the same key: two entries may share a filetype, and one
      -- may borrow another's parser. Walking a sorted list keeps every table
      -- built below the same from one session to the next.
      local language_names = vim.tbl_keys(languages)
      table.sort(language_names)

      -- The language that owns a parser is the one carrying the parser's name
      -- among its own filetypes (`cpp` owns `cpp`, `arduino` only borrows it).
      ---@type table<string, string>
      local ft_owner = {}
      for _, name in ipairs(language_names) do
        for _, ft in ipairs(languages[name].filetypes) do
          ft_owner[ft] = ft_owner[ft] or name
        end
      end

      -- Add each formatter's own config to the list of tools if exist
      for _, name in ipairs(language_names) do
        for _, tool in ipairs(languages[name].formatters or {}) do
          if type(tool) == 'table' and tool.opts then
            opts.formatters[tool[1]] =
              vim.tbl_extend('force', opts.formatters[tool[1]] or {}, tool.opts)
          end
        end
      end

      -- `injected` works in treesitter language names, the rest of this config
      -- works in filetypes, and the two part ways often enough (`bash` -> `sh`)
      -- to need a map. It also names the scratch file it hands a formatter
      -- after the language, so a language whose extension differs (`query` ->
      -- `scm`) needs a second one.
      ---@return table<string, string> lang_to_ft
      ---@return table<string, string> lang_to_ext
      local function build_injected_maps()
        local lang_to_ft, lang_to_ext = {}, {}
        for _, name in ipairs(language_names) do
          local language = languages[name]
          local parser = language.parser
          local parser_name = type(parser) == 'table' and parser[1] or parser
          local owner = parser_name and ft_owner[parser_name]
          if
            parser_name
            -- An entry that borrows another language's parser must not speak
            -- for it: `jupyter` reads JSON but formats with `jupytext`, and a
            -- ```json block is not a notebook.
            and (owner == nil or owner == name)
            and not vim.tbl_isempty(language.formatters or {})
          then
            -- A parser that is also a filetype needs no entry: `injected`
            -- already falls back to the language name.
            if owner == nil then
              lang_to_ft[parser_name] = language.filetypes[1]
            end
            if language.ext then lang_to_ext[parser_name] = language.ext end
          end
        end
        return lang_to_ft, lang_to_ext
      end

      -- Where the clean-up of `*` would change what the file means: a Markdown
      -- hard break is two trailing spaces, an empty context line of a patch
      -- is a single space.
      local finish_formatters_by_ft
      local keep_trailing_space =
        { diff = true, gitsendemail = true, mail = true, markdown = true }
      -- A filetype with a formatter of its own leaves blank lines to it:
      -- Python's two between definitions are not to be squeezed into one.
      local own_blank_lines = { diff = true, markdown = true }

      --- Turn the `*` entry into a function of the buffer, and let the
      --- language server format any filetype left without a formatter
      ---
      --- conform adds the `*` list to every filetype, and `lsp_format =
      --- 'fallback'` only asks the server when that whole list is empty --
      --- which, with `*` in it, it never is.
      ---
      --- `declared` holds the filetypes `config.languages` gives a formatter,
      --- installed or not: while it is missing the server formats in its
      --- place, and the blank lines are still not `*`'s to squeeze.
      ---@param by_ft table<string, string[]>
      ---@param declared table<string, true>
      ---@return table<string, any>
      finish_formatters_by_ft = function(by_ft, declared)
        local common = by_ft['*'] or {}
        by_ft['*'] = function(bufnr)
          local ft = vim.bo[bufnr].filetype
          local base = ft:match('^[^.]+') or ft
          local has_own = declared[ft] or declared[base] or false
          return vim.tbl_filter(function(name)
            if name == 'trim_whitespace' then
              return not keep_trailing_space[base]
            elseif name == 'condense_blank_lines' then
              return not has_own and not own_blank_lines[base]
            elseif name == 'trim_newlines' then
              return base ~= 'diff'
            end
            return true
          end, common)
        end
        for ft, tools in pairs(by_ft) do
          if type(tools) == 'table' and #tools == 0 then
            by_ft[ft] = { lsp_format = 'last' }
          end
        end
        by_ft._ = { lsp_format = 'last' }
        return by_ft
      end

      -- `config.languages` owns the formatters of a filetype, so a filetype it
      -- names is always assigned, empty list included. But more than one entry
      -- may name the same filetype, so the lists are built whole and assigned
      -- once instead of each entry resetting the key it happens to touch.
      ---@return table<string, string[]>
      local function build_formatters_by_ft()
        local by_ft, declared = {}, {}
        for _, name in ipairs(language_names) do
          local language = languages[name]
          for _, ft in ipairs(language.filetypes) do
            by_ft[ft] = by_ft[ft] or {}
          end
          for _, tool in ipairs(language.formatters or {}) do
            local tool_name, tool_command
            if type(tool) == 'string' then
              tool_name = tool
              tool_command = tool
            else
              tool_name = tool[1]
              tool_command = tool.command or tool_name
            end
            local fts = type(tool) == 'table' and tool.filetypes
              or language.filetypes
            if name ~= '*' and tool_name ~= 'injected' then
              for _, ft in ipairs(fts) do
                declared[ft] = true
              end
            end
            if
              require('util.languages').is_available(tool_command)
              or name == '*'
              or tool_name == 'injected'
            then
              for _, ft in ipairs(fts) do
                table.insert(by_ft[ft], tool_name)
              end
            end
          end
        end
        return finish_formatters_by_ft(by_ft, declared)
      end

      for ft, tools in pairs(build_formatters_by_ft()) do
        opts.formatters_by_ft[ft] = tools
      end

      -- A formatter Mason installs during the session was not on `$PATH` when
      -- the lists above were built, so it would sit unused until the next
      -- restart. Rebuilding once an install lands closes that gap.
      require('util.plugin').on_load('mason.nvim', function()
        require('mason-registry'):on('package:install:success', function()
          vim.schedule(function()
            local formatters_by_ft = require('conform').formatters_by_ft
            for ft, tools in pairs(build_formatters_by_ft()) do
              formatters_by_ft[ft] = tools
            end
          end)
        end)
      end)

      local lang_to_ft, lang_to_ext = build_injected_maps()

      ---@param lang string
      ---@return boolean
      local function has_parser(lang)
        if lang:match('[%w_]+') ~= lang then return false end
        if vim.treesitter.language.add(lang) then return true end
        -- What `LanguageTree` does next: an alias may still name a parser
        -- registered under another language (`json` -> `json5` here).
        local aliased = vim.treesitter.language.get_lang(lang)
        return aliased ~= nil
          and aliased ~= lang
          and vim.treesitter.language.add(aliased) == true
      end

      -- A block whose parser is missing yields no language tree at all, so
      -- `injected` never sees it and the block quietly stays unformatted.
      -- Report it once per language, and only when a formatter was waiting for
      -- it, so a ```mermaid block nobody formats says nothing.
      ---@type table<string, true>
      local reported = {}
      ---@param buf integer
      local function report_missing_parsers(buf)
        local buf_lang = vim.treesitter.language.get_lang(vim.bo[buf].filetype)
        if not buf_lang then return end
        local query = vim.treesitter.query.get(buf_lang, 'injections')
        local ok, parser = pcall(vim.treesitter.get_parser, buf, buf_lang)
        if not query or not ok or not parser then return end
        pcall(parser.parse, parser)

        local formatters_by_ft = require('conform').formatters_by_ft
        local missing = {}
        for _, tree in ipairs(parser:trees()) do
          for _, match, metadata in query:iter_matches(tree:root(), buf) do
            local lang = metadata['injection.language'] --[[@as string?]]
            for id, nodes in pairs(match) do
              if query.captures[id] == 'injection.language' then
                lang = vim.treesitter.get_node_text(nodes[#nodes], buf)
              end
            end
            -- The normalisation `LanguageTree` applies before it looks a
            -- parser up; without it a ```C++ or a trailing newline never
            -- matches what is installed.
            lang = lang and lang:gsub('%s+', ''):lower():gsub('%-', '_')
            if lang and lang ~= '' and not missing[lang] then
              local ft = lang_to_ft[lang] or lang
              if
                not has_parser(lang)
                and type(formatters_by_ft[ft]) == 'table'
                and #formatters_by_ft[ft] > 0
              then
                missing[lang] = true
              end
            end
          end
        end

        local langs = vim.tbl_keys(missing)
        table.sort(langs)
        for _, lang in ipairs(langs) do
          if not reported[lang] then
            reported[lang] = true
            local message = string.format(
              'No treesitter parser for `%s`, its code blocks stay unformatted.\nRun `:TSInstall %s` to format them.',
              lang,
              lang
            )
            vim.schedule(
              function()
                require('util.notify').titled('Format')(
                  message,
                  vim.log.levels.WARN
                )
              end
            )
          end
        end
      end

      -- Conform merges this on top of its own `injected` definition, and the
      -- defaults above already put `ignore_errors` there, so extend instead
      -- of replacing: a bare assignment loses whichever side runs first.
      opts.formatters.injected =
        vim.tbl_deep_extend('force', opts.formatters.injected or {}, {
          options = { lang_to_ft = lang_to_ft, lang_to_ext = lang_to_ext },
          format = function(self, ctx, lines, callback)
            report_missing_parsers(ctx.buf)
            require('conform.formatters.injected').format(
              self,
              ctx,
              lines,
              callback
            )
          end,
        })
      return opts
    end,
    -- Saving is `util.format`'s job, so conform must not format on its own
    ---@param opts conform.setupOpts
    config = function(_, opts)
      opts.format_on_save = nil
      opts.format_after_save = nil
      require('conform').setup(opts)
    end,
  },
  {
    -- Auto install formatters
    'mason-org/mason.nvim',
    opts = function(_, opts)
      local languages = require('config.languages')
      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        for _, tool in ipairs(language.formatters or {}) do
          local is_mason_tool = true
          if type(tool) == 'table' and tool.mason then
            is_mason_tool = tool.mason.enabled ~= false
          end
          local tool_package = require('util.languages').get_mason_package(tool)
          if is_mason_tool then
            -- install the formatters of bundle languages, `*` and `_` up front
            if
              vim.list_contains(DyNeo.bundle_languages, name)
              or name == '*'
              or name == '_'
            then
              table.insert(opts.ensure_installed, tool_package)
            end
            -- and the others once a buffer of their language opens
            if vim.list_contains(DyNeo.enabled_languages, name) then
              require('util.lazy_install').on_filetype(
                language.filetypes,
                function()
                  require('util.lazy_install').install_once(tool_package)
                end
              )
            end
          end
        end
      end
    end,
  },
}
