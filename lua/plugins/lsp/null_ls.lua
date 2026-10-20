return {
  {
    -- Use null-ls for formatting/diagnostics with some none-LSP tools
    'nvimtools/none-ls.nvim',
    event = 'LazyFile',
    dependencies = { 'mason.nvim' },
    init = function()
      require('util.plugin').on_very_lazy(function()
        -- Format through null-ls ahead of conform and the LSP formatter
        require('util.format').register({
          name = 'none-ls.nvim',
          priority = 200,
          primary = true,
          format = function(buf)
            return require('util.lsp').format({
              bufnr = buf,
              filter = function(client) return client.name == 'null-ls' end,
            })
          end,
          sources = function(buf)
            local ret = require('null-ls.sources').get_available(
              vim.bo[buf].filetype,
              'NULL_LS_FORMATTING'
            ) or {}
            return vim.tbl_map(function(source) return source.name end, ret)
          end,
        })
      end)
    end,
    -- Only the sources of `config.languages`, none of the defaults
    config = function(_, opts)
      local null_ls = require('null-ls')
      opts.root_dir = opts.root_dir
        or require('null-ls.utils').root_pattern(
          '.null-ls-root',
          '.neoconf.json',
          'Makefile',
          '.git'
        )
      -- A source that reads a file (`ltcc`) gets a copy of the buffer.
      -- Next to the file, a copy left by a quit mid-run lands in the
      -- repository, ready to be committed; Neovim's own temp folder is
      -- private to the user and removed when it exits.
      opts.temp_dir = opts.temp_dir or vim.fs.dirname(vim.fn.tempname())
      opts.sources = {}

      -- Its sources run linters and formatters that load the project's own
      -- config and plugins, so none attaches to a buffer under a directory
      -- still held untrusted. Released, the buffers get it from `try_add`.
      local should_attach = opts.should_attach
      opts.should_attach = function(bufnr)
        if require('util.untrusted').held(bufnr) then return false end
        return not should_attach or should_attach(bufnr)
      end
      require('util.untrusted').on_release(
        'none-ls',
        function(bufnr) require('null-ls.client').try_add(bufnr) end
      )

      -- Unified null_ls source configs
      local source_configs = {}
      local languages = require('config.languages')
      local keys = {}
      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        for _, tool in ipairs(language.null_ls or {}) do
          local tool_name = tool[1]
          local key = tool.type .. '.' .. tool_name
          -- A source's own filetypes win over the language's; `*` with none
          -- of its own is every filetype, an empty list to none-ls
          local filetypes = tool.filetypes
            or (name == '*' and {} or language.filetypes)
          if source_configs[key] then
            source_configs[key].filetypes =
              vim.list_extend(source_configs[key].filetypes, filetypes)
          else
            source_configs[key] =
              { info = tool, filetypes = vim.deepcopy(filetypes) }
            table.insert(keys, key)
          end
        end
      end

      -- Setup null_ls configs with predefined file types
      for _, key in ipairs(keys) do
        local config = source_configs[key]
        table.insert(
          opts.sources,
          require(
            (config.info.custom and 'tools.' or 'null-ls.builtins.')
              .. config.info.type
              .. '.'
              .. config.info[1]
          ).with({
            filetypes = config.filetypes,
            -- A source that sends the buffer off the machine skips one whose
            -- content must stay on it
            runtime_condition = config.info.remote
                and function(params)
                  return not require('util.sensitive').is_sensitive(
                    params.bufnr
                  )
                end
              or nil,
          })
        )
      end

      -- null-ls answers `supports_method` from the filetype of the current
      -- buffer and ignores the buffer it is asked about. Otter forwards
      -- requests from a markdown buffer to its hidden `.otter.py` buffer, so
      -- null-ls would claim completion there on the strength of a markdown
      -- source, answer first with no items, and that empty list would win
      -- over the real language server's
      local on_init = opts.on_init
      opts.on_init = function(client, initialize_result)
        local supports_method = client.supports_method
        client.supports_method = function(self, method, bufnr)
          if type(bufnr) == 'table' then bufnr = bufnr.bufnr end
          if
            bufnr
            and bufnr ~= 0
            and bufnr ~= vim.api.nvim_get_current_buf()
            and vim.api.nvim_buf_is_loaded(bufnr)
          then
            return vim.api.nvim_buf_call(
              bufnr,
              function() return supports_method(self, method) end
            )
          end
          return supports_method(self, method)
        end
        if on_init then on_init(client, initialize_result) end
      end
      null_ls.setup(opts)
    end,
  },
  {
    -- Auto install tools
    'mason-org/mason.nvim',
    opts = function(_, opts)
      opts.ensure_installed = opts.ensure_installed or {}
      local languages = require('config.languages')
      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        for _, tool in ipairs(language.null_ls or {}) do
          local tool_package = require('util.languages').get_mason_package(tool)
          local is_mason_tool = true
          if type(tool) == 'table' and tool.mason then
            is_mason_tool = tool.mason.enabled ~= false
          end
          if is_mason_tool then
            -- install the tools of bundle languages, `*` and `_` up front
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
