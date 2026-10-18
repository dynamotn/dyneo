local TS = require('util.treesitter')
local Plugin = require('util.plugin')

--- Parsers an install was started for this session
---@type table<string, true>
local attempted = {}

return {
  {
    'nvim-treesitter/nvim-treesitter',
    branch = 'main',
    -- The last release is far too old for the `main` branch API
    version = false,
    build = function()
      local treesitter = require('nvim-treesitter')
      if not treesitter.get_installed then
        Plugin.error(
          'Please restart Neovim and run `:TSUpdate` to use the `nvim-treesitter` **main** branch.'
        )
        return
      end
      TS.build(function() treesitter.update(nil, { summary = true }) end)
    end,
    event = { 'LazyFile', 'VeryLazy' },
    cmd = { 'TSUpdate', 'TSInstall', 'TSLog', 'TSUninstall' },
    opts_extend = { 'ensure_installed' },
    ---@alias TSFeat { enable?: boolean, disable?: string[] }
    opts = {
      indent = { enable = true }, ---@type TSFeat
      highlight = { enable = true }, ---@type TSFeat
      folds = { enable = true }, ---@type TSFeat
      ensure_installed = {
        'diff', -- for diff file
        'comment', -- for comment tags
        'query', -- for treesitter itself query
        'regex', -- for regex
        'vim', -- for old vim script
        'vimdoc', -- for vim help files
        'git_config', -- for git config
        'gitignore', -- for git ignore
        'gitattributes', -- for git attributes

        -- for latest build of neovim-git on Arch
        'c',
        'lua',
        'markdown',
      },
    },
    config = function(_, opts)
      local treesitter = require('nvim-treesitter')
      if not treesitter.get_installed then
        return Plugin.error('Please use `:Lazy` and update `nvim-treesitter`')
      end
      -- Setup from opts
      treesitter.setup(opts)
      TS.get_installed(true) -- initialize the installed langs

      -- Setup treesitter parser to work with defined filetypes
      local parsers = require('nvim-treesitter.parsers')
      -- Where a parser of `config.languages` is laid over nvim-treesitter's
      -- list again on each `:TSUpdate`; set up anew, not added to
      local parser_group = vim.api.nvim_create_augroup(
        'dyneo_treesitter_parsers',
        { clear = true }
      )
      local languages = require('config.languages')
      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        if language.parser then
          -- Get my config
          local parser_name = ''
          local parser = language.parser
          if type(parser) == 'string' then
            parser_name = parser
          elseif type(parser) == 'table' then
            parser_name = parser[1]
            if parsers[parser_name] then
              vim.api.nvim_create_autocmd('User', {
                group = parser_group,
                pattern = 'TSUpdate',
                callback = function()
                  parsers[parser_name].install_info = parser.install_info
                end,
              })
            else
              vim.api.nvim_create_autocmd('User', {
                group = parser_group,
                pattern = 'TSUpdate',
                callback = function()
                  require('nvim-treesitter.parsers')[parser_name] = {
                    install_info = parser.install_info,
                    tier = 0,
                  }
                end,
              })
            end
          end
          for _, ft in pairs(language.filetypes) do
            vim.treesitter.language.register(parser_name, ft)
          end

          -- An injection names the parser it wants and is dropped without a
          -- word when that parser is missing, so a language carries the
          -- parsers its queries inject along with its own.
          local injected_parsers = language.injected_parsers or {}

          -- install parser of language in bundle languages
          if vim.list_contains(DyNeo.bundle_languages, name) then
            table.insert(opts.ensure_installed, parser_name)
            vim.list_extend(opts.ensure_installed, injected_parsers)
          end
          -- lazy install parser of language not in bundle languages
          if vim.list_contains(DyNeo.enabled_languages, name) then
            local wanted = { parser_name }
            vim.list_extend(wanted, injected_parsers)
            require('util.lazy_install').on_filetype(
              language.filetypes,
              function(ev)
                local installed = TS.get_installed()
                local missing = vim.tbl_filter(
                  function(parser) return not installed[parser] end,
                  wanted
                )
                -- Tried once a session: a parser that fails to build would
                -- otherwise be built again on every buffer of the language
                missing = vim.tbl_filter(
                  function(parser) return not attempted[parser] end,
                  missing
                )
                if #missing > 0 then
                  for _, parser in ipairs(missing) do
                    attempted[parser] = true
                  end
                  treesitter
                    .install(missing, { summary = true })
                    :await(function()
                      -- refresh the installed langs
                      TS.get_installed(true)
                      -- Set up the buffer again rather than `:e!` it, which
                      -- would drop what was typed while the parser built
                      if vim.api.nvim_buf_is_loaded(ev.buf) then
                        vim.bo[ev.buf].filetype = vim.bo[ev.buf].filetype
                      end
                    end)
                end
              end
            )
          end
        end
      end

      -- install missing parsers
      opts.ensure_installed = Plugin.dedup(opts.ensure_installed)
      -- By parser name: `TS.have` takes a filetype, and a filetype given to
      -- another parser (`c` to `cpp`) would answer for that one instead
      local installed = TS.get_installed()
      local install = vim.tbl_filter(
        function(parser_name) return installed[parser_name] == nil end,
        opts.ensure_installed or {}
      )
      if #install > 0 then
        TS.build(function()
          treesitter.install(install, { summary = true }):await(function()
            TS.get_installed(true) -- refresh the installed langs
          end)
        end)
      end

      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup(
          'dyneo_treesitter',
          { clear = true }
        ),
        callback = function(ev)
          local ft, lang = ev.match, vim.treesitter.language.get_lang(ev.match)
          if not TS.have(ft) then return end

          ---@param feat string
          ---@param query string
          local function enabled(feat, query)
            local f = opts[feat] or {} ---@type TSFeat
            return f.enable ~= false
              and not (type(f.disable) == 'table' and vim.tbl_contains(
                f.disable,
                lang
              ))
              and TS.have(ft, query)
          end

          -- highlighting
          if enabled('highlight', 'highlights') then
            pcall(vim.treesitter.start, ev.buf)
          end

          -- indents
          if enabled('indent', 'indents') then
            Plugin.set_default(
              'indentexpr',
              "v:lua.require'util.treesitter'.indentexpr()"
            )
          end

          -- folds
          if enabled('folds', 'folds') then
            if Plugin.set_default('foldmethod', 'expr') then
              Plugin.set_default(
                'foldexpr',
                "v:lua.require'util.treesitter'.foldexpr()"
              )
            end
          end
        end,
      })
    end,
  },
}
