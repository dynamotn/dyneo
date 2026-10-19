local Plugin = require('util.plugin')
local Lsp = require('util.lsp')

--- Read the project's settings (`.vscode/settings.json` and the like) into
--- the config of a server about to start
---@param config vim.lsp.ClientConfig
local function with_local_settings(_, config)
  require('codesettings').with_local_settings(config.name, config)
end

--- The servers nvim-lspconfig ships with a `before_init` of their own
local OWN_BEFORE_INIT = {
  astro = true,
  eslint = true,
  golangci_lint_ls = true,
  mdx_analyzer = true,
  oxlint = true,
  tailwindcss = true,
}

--- The `before_init` of `lsp/<server>.lua` on the runtimepath, if any
---@param server string
---@return function?
local function shipped_before_init(server)
  for _, file in
    ipairs(vim.api.nvim_get_runtime_file('lsp/' .. server .. '.lua', true))
  do
    local ok, config = pcall(dofile, file)
    if ok and type(config) == 'table' and config.before_init then
      return config.before_init
    end
  end
end

--- The `root_dir` and `root_markers` of `lsp/<server>.lua` on the
--- runtimepath, later files over earlier ones as `vim.lsp` merges them
---@param server string
---@return { root_dir?: string|function, root_markers?: table }
local function shipped_root(server)
  local root = {}
  for _, file in
    ipairs(vim.api.nvim_get_runtime_file('lsp/' .. server .. '.lua', true))
  do
    local ok, config = pcall(dofile, file)
    if ok and type(config) == 'table' then
      root.root_dir = config.root_dir or root.root_dir
      root.root_markers = config.root_markers or root.root_markers
    end
  end
  return root
end

--- Defaults under whatever the specs loaded ahead of this one set
---@return PluginLspOpts
local function default_opts()
  local icons = require('config.defaults').icons.diagnostics
  ---@class PluginLspOpts
  local ret = {
    ---@type vim.diagnostic.Opts
    diagnostics = {
      underline = true,
      update_in_insert = false,
      -- tiny-inline-diagnostic draws the messages when it is in the spec.
      -- Decided here, the one place diagnostics are configured: this spec
      -- loads on the first file, so on a start without one it comes after
      -- tiny-inline's `VeryLazy` and would turn the native text back on.
      virtual_text = not Plugin.has('tiny-inline-diagnostic.nvim') and {
        spacing = 4,
        source = 'if_many',
        prefix = '●',
      },
      severity_sort = true,
      signs = {
        text = {
          [vim.diagnostic.severity.ERROR] = icons.Error,
          [vim.diagnostic.severity.WARN] = icons.Warn,
          [vim.diagnostic.severity.HINT] = icons.Hint,
          [vim.diagnostic.severity.INFO] = icons.Info,
        },
      },
    },
    inlay_hints = {
      enabled = true,
      exclude = { 'vue' }, -- filetypes without inlay hints
    },
    codelens = {
      enabled = false,
    },
    -- Options for `vim.lsp.buf.format`
    format = {
      formatting_options = nil,
      timeout_ms = nil,
    },
    -- `*` is the default of every server. On top of `vim.lsp.Config`, a
    -- server takes `enabled` and `keys`, keys with `has` limited to servers
    -- supporting that method.
    ---@type table<string, vim.lsp.Config|{ enabled?: boolean, keys?: LspKeysSpec[] }|boolean>
    servers = {
      ['*'] = {
        capabilities = {
          workspace = {
            fileOperations = {
              didRename = true,
              willRename = true,
            },
          },
        },
        -- stylua: ignore
        keys = {
          { '<leader>cl', function() Snacks.picker.lsp_config() end, desc = 'Lsp Info' },
          { 'gd', vim.lsp.buf.definition, desc = 'Goto Definition', has = 'definition' },
          { 'gr', vim.lsp.buf.references, desc = 'References', nowait = true },
          { 'gI', vim.lsp.buf.implementation, desc = 'Goto Implementation' },
          { 'gy', vim.lsp.buf.type_definition, desc = 'Goto T[y]pe Definition' },
          { 'gD', vim.lsp.buf.declaration, desc = 'Goto Declaration' },
          { 'K', function() return vim.lsp.buf.hover() end, desc = 'Hover' },
          { 'gK', function() return vim.lsp.buf.signature_help() end, desc = 'Signature Help', has = 'signatureHelp' },
          { '<leader>ca', vim.lsp.buf.code_action, desc = 'Code Action', mode = { 'n', 'x' }, has = 'codeAction' },
          { '<leader>cc', vim.lsp.codelens.run, desc = 'Run Codelens', mode = { 'n', 'x' }, has = 'codeLens' },
          { '<leader>cC', function() Lsp.codelens.toggle() end, desc = 'Toggle Codelens', mode = { 'n' }, has = 'codeLens' },
          { '<leader>cr', vim.lsp.buf.rename, desc = 'Rename', has = 'rename' },
          { '<leader>cA', Lsp.action.source, desc = 'Source Action', has = 'codeAction' },
          { ']]', function() Snacks.words.jump(vim.v.count1) end, has = 'documentHighlight',
            desc = 'Next Reference', enabled = function() return Snacks.words.is_enabled() end },
          { '[[', function() Snacks.words.jump(-vim.v.count1) end, has = 'documentHighlight',
            desc = 'Prev Reference', enabled = function() return Snacks.words.is_enabled() end },
          { '<a-n>', function() Snacks.words.jump(vim.v.count1, true) end, has = 'documentHighlight',
            desc = 'Next Reference', enabled = function() return Snacks.words.is_enabled() end },
          { '<a-p>', function() Snacks.words.jump(-vim.v.count1, true) end, has = 'documentHighlight',
            desc = 'Prev Reference', enabled = function() return Snacks.words.is_enabled() end },
          {
            '<leader>co',
            Lsp.action['source.organizeImports'],
            desc = 'Organize Imports',
            has = 'codeAction',
            enabled = function(buf)
              local code_actions = vim.tbl_filter(
                function(action) return action:find('^source%.organizeImports%.?$') end,
                Lsp.code_actions({ bufnr = buf })
              )
              return #code_actions > 0
            end,
          },
        },
      },
      stylua = { enabled = false },
    },
    -- Per server, or `*` for any: a function returning true sets the server
    -- up itself, and keeps it from `vim.lsp.config`
    ---@type table<string, fun(server: string, opts: vim.lsp.Config): boolean?>
    setup = {},
  }
  return ret
end

return {
  {
    -- I want to self-managed LSP by my way
    'neovim/nvim-lspconfig',
    event = { 'BufReadPre', 'BufNewFile', 'BufWritePre' },
    opts_extend = { 'servers.*.keys' },
    dependencies = {
      'mason.nvim',
      {
        -- Auto install LSP servers with needed. Set up from the `config`
        -- below, not on its own.
        'mason-org/mason-lspconfig.nvim',
        dependencies = { 'mason-org/mason.nvim' },
        config = function() end,
      },
      {
        -- Route npm and pip through bun and uv
        --
        -- Both read their own configuration from `~/.config`, so every mason
        -- install through them is held to the quarantine set there --
        -- `minimumReleaseAge` in `.bunfig.toml`, `exclude-newer` in
        -- `uv/uv.toml` -- on top of the aged registry snapshot
        -- `tools.mason-quarantine` picks. swapson has no window of its own.
        'dynamotn/swapson.nvim',
        opts = {
          -- `npm.enabled` covers the version lookups too, which is what the
          -- retired `patch_version_lookup` used to switch on its own.
          npm = {
            enabled = true,
            tool = 'bun',
          },
          pip = {
            enabled = true,
            tool = 'uv',
          },
        },
      },
    },
    keys = {
      {
        -- Neovim's own `vim.lsp.buf.workspace_diagnostics()` only reaches a
        -- server that answers `workspace/diagnostic`, and few do yet, so the
        -- others are handed every file of the project instead.
        '<leader>xw',
        function() require('tools.workspace_diagnostics').run() end,
        mode = { 'n' },
        desc = 'Workspace Diagnostics',
      },
    },
    opts = function(_, opts)
      local defaults = default_opts()
      -- The default keys go first, so a key added by an earlier spec for the
      -- same `lhs` still wins
      local keys = vim.tbl_get(opts, 'servers', '*', 'keys') or {}
      opts = vim.tbl_deep_extend('keep', opts, defaults)
      opts.servers['*'].keys = vim.list_extend(defaults.servers['*'].keys, keys)
      opts.servers['*'].before_init = with_local_settings
      return opts
    end,
    ---@param opts PluginLspOpts
    config = function(_, opts)
      -- setup auto format
      require('util.format').register(Lsp.formatter())

      -- setup keymaps, `*` first so a server's own key for the same `lhs`
      -- is set after it and wins
      local names = vim.tbl_keys(opts.servers) ---@type string[]
      table.sort(names, function(a, b)
        if a == '*' or b == '*' then return a == '*' and b ~= '*' end
        return a < b
      end)
      for _, server in ipairs(names) do
        local server_opts = opts.servers[server]
        if type(server_opts) == 'table' and server_opts.keys then
          Lsp.keymaps.set(
            { name = server ~= '*' and server or nil },
            server_opts.keys
          )
        end
      end

      -- inlay hints
      if opts.inlay_hints.enabled then
        Snacks.util.lsp.on(
          { method = 'textDocument/inlayHint' },
          function(buffer)
            if
              vim.api.nvim_buf_is_valid(buffer)
              and vim.bo[buffer].buftype == ''
              and not vim.tbl_contains(
                opts.inlay_hints.exclude,
                vim.bo[buffer].filetype
              )
            then
              vim.lsp.inlay_hint.enable(true, { bufnr = buffer })
            end
          end
        )
      end

      -- code lens
      if opts.codelens.enabled and vim.lsp.codelens then
        Snacks.util.lsp.on(
          { method = 'textDocument/codeLens' },
          Lsp.codelens.enable
        )
      end

      if
        type(opts.diagnostics.virtual_text) == 'table'
        and opts.diagnostics.virtual_text.prefix == 'icons'
      then
        opts.diagnostics.virtual_text.prefix = function(diagnostic)
          local icons = require('config.defaults').icons.diagnostics
          for d, icon in pairs(icons) do
            if diagnostic.severity == vim.diagnostic.severity[d:upper()] then
              return icon
            end
          end
          return '●'
        end
      end
      vim.diagnostic.config(vim.deepcopy(opts.diagnostics))

      -- default capabilities
      if opts.capabilities then
        opts.servers['*'] =
          vim.tbl_deep_extend('force', opts.servers['*'] or {}, {
            capabilities = opts.capabilities,
          })
      end
      if opts.servers['*'] then vim.lsp.config('*', opts.servers['*']) end

      -- get all the servers that are available through mason-lspconfig
      local mason_configs =
        require('mason-lspconfig').get_mappings().lspconfig_to_package
      local ensure_installed = {} ---@type string[]
      -- mason-lspconfig enables every server it has installed, so the ones a
      -- plugin starts itself, or that are turned off, are kept from it
      local mason_exclude = {} ---@type string[]

      -- get all the servers that are available through my config
      local languages = require('config.languages')

      -- Every filetype whose language declares a server, keyed by server. A
      -- language entry naming a server is the only place that says the server
      -- belongs to those filetypes, so without this a bare `harper_ls = {}` in
      -- a language's plugin spec attaches nothing, and the one spec that does
      -- set `filetypes` narrows the server down to its own language. An entry
      -- with its own `filetypes` claims only those, so a server for one
      -- dialect of YAML is not widened to every other.
      local declared_filetypes = {} ---@type table<string, string[]>
      -- Servers some entry gives filetypes of its own: their shipped
      -- default is what that entry narrows them from
      local narrowed = {} ---@type table<string, true>
      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        -- '*' and '_' are pseudo filetypes, not something a server attaches to
        if
          not vim.list_contains(language.filetypes, '*')
          and not vim.list_contains(language.filetypes, '_')
        then
          for _, lsp_server in ipairs(language.lsp_servers or {}) do
            local server = type(lsp_server) == 'table' and lsp_server[1]
              or lsp_server--[[@as string]]
            if type(lsp_server) == 'table' and lsp_server.filetypes then
              narrowed[server] = true
            end
            declared_filetypes[server] = vim.list_extend(
              declared_filetypes[server] or {},
              type(lsp_server) == 'table' and lsp_server.filetypes
                or language.filetypes
            )
          end
        end
      end

      -- Reading `vim.lsp.config[server]` is not a table lookup: for a server
      -- nothing has enabled yet, every read searches the runtimepath for
      -- `lsp/<server>.lua`, runs what it finds and merges the result again.
      -- With a server named by several languages that cost is paid on each
      -- of them, so the widened filetypes are worked out once per server.
      local widened_filetypes = {} ---@type table<string, string[]>
      ---@param server string
      ---@param server_opts vim.lsp.Config
      ---@return string[]
      local function widen_filetypes(server, server_opts)
        if not widened_filetypes[server] then
          local filetypes = vim.deepcopy(
            server_opts.filetypes
              or not narrowed[server] and (vim.lsp.config[server] or {}).filetypes
              or {}
          )
          widened_filetypes[server] =
            Plugin.dedup(vim.list_extend(filetypes, declared_filetypes[server]))
        end
        return widened_filetypes[server]
      end

      -- The per-buffer condition of each server, from whichever language
      -- gave one: a language naming the server plainly must not drop it
      local conditions = {} ---@type table<string, fun(bufnr: integer): boolean>

      --- A `root_dir` turning a buffer down where the server must not run.
      --- `vim.lsp` only attaches once `root_dir` hands a directory to
      --- `on_dir`, so withholding the call is how a buffer is turned down:
      --- one the server's condition rejects, or one under a held directory
      --- (a review's worktree), whose code the server would run. Decided per
      --- buffer, since deciding once at startup would pin the answer to
      --- whatever directory Neovim was launched from.
      ---@param server string
      ---@param server_opts vim.lsp.Config
      ---@return fun(bufnr: integer, on_dir: fun(root_dir?: string))
      local function guarded_root_dir(server, server_opts)
        local root_dir, root_markers ---@type any, any
        local resolved = false
        return function(bufnr, on_dir)
          local condition = conditions[server]
          if condition and not condition(bufnr) then return end
          if require('util.untrusted').held(bufnr) then return end
          -- What `lsp/<server>.lua` ships is read on the first buffer, not
          -- at startup: resolving `vim.lsp.config[server]` searches the
          -- runtimepath for every server, and once configured it answers
          -- with this very function.
          if not resolved then
            resolved = true
            local shipped = shipped_root(server)
            local star = vim.lsp.config['*'] or {}
            root_dir = server_opts.root_dir or shipped.root_dir or star.root_dir
            root_markers = server_opts.root_markers
              or shipped.root_markers
              or star.root_markers
          end
          if type(root_dir) == 'function' then
            return root_dir(bufnr, on_dir)
          end
          -- A custom `root_dir` makes `vim.lsp` skip `root_markers`, so
          -- they are resolved here in its place.
          on_dir(
            root_dir
              or (root_markers and vim.fs.root(bufnr, root_markers))
              or nil
          )
        end
      end

      ---@param server string
      ---@param enabled? fun(bufnr: integer): boolean
      ---@param name string
      ---@param language DyLangSpec
      local function configure(server, enabled, name, language)
        if server == '*' then return end
        if enabled then conditions[server] = enabled end
        -- `false` turns a server off; a server nobody mentions is on
        local server_opts = opts.servers[server]
        if server_opts == nil then server_opts = {} end
        server_opts = server_opts == true and {}
          or (not server_opts) and { enabled = false }
          or server_opts--[[@as vim.lsp.Config]]

        -- Widen the server to every filetype that declares it, starting from
        -- whatever its plugin spec asked for, or its shipped default when the
        -- spec is silent. Copied, because `opts.servers` is shared between the
        -- calls this function gets for each language.
        if declared_filetypes[server] then
          server_opts = vim.tbl_extend('force', server_opts, {
            filetypes = vim.deepcopy(widen_filetypes(server, server_opts)),
          })
        end

        -- automatic install lsp servers
        if mason_configs[server] then
          -- install server of language in bundle languages
          if vim.list_contains(DyNeo.bundle_languages, name) then
            table.insert(ensure_installed, server)
          end
          -- lazy install server of language not in bundle languages
          if vim.list_contains(DyNeo.enabled_languages, name) then
            require('util.lazy_install').on_filetype(
              language.filetypes,
              function(args)
                -- Whether the package is there is asked first: that is one
                -- `stat`, where resolving the config searches the runtimepath,
                -- and this runs for every buffer of these filetypes although
                -- the server is nearly always installed already.
                local server_package = mason_configs[server]
                if require('mason-registry').is_installed(server_package) then
                  return
                end
                local lsp_config = vim.lsp.config[server]
                if lsp_config == nil then return end
                if enabled and not enabled(args.buf) then return end
                if require('util.untrusted').held(args.buf) then return end
                if
                  lsp_config.filetypes == nil
                  or vim.tbl_contains(lsp_config.filetypes, args.match)
                then
                  require('util.lazy_install').install_once(server_package)
                end
              end
            )
          end
        end

        local setup = opts.setup[server] or opts.setup['*']
        if setup and setup(server, server_opts) then
          table.insert(mason_exclude, server)
          return
        end
        if server_opts.enabled == false then
          table.insert(mason_exclude, server)
          return
        end
        -- A server shipping a `before_init` of its own has it laid over the
        -- one of `*`, and would never read the project's settings
        if server_opts.before_init == nil and OWN_BEFORE_INIT[server] then
          local own = shipped_before_init(server)
          server_opts = vim.tbl_extend('force', server_opts, {
            before_init = function(params, config)
              if own then own(params, config) end
              with_local_settings(params, config)
            end,
          })
        end
        server_opts = vim.tbl_extend('force', server_opts, {
          root_dir = guarded_root_dir(server, server_opts),
        })
        -- Merged into what was set for the server so far, not into its
        -- resolved config: resolving it here would search the runtimepath
        -- once more, and `vim.lsp` lays `lsp/<server>.lua` and `*` underneath
        -- on its own when the server starts.
        vim.lsp.config(server, server_opts)

        -- manually enable if this is a server that cannot be installed with mason-lspconfig
        if not mason_configs[server] then
          vim.lsp.enable(server)
          return
        end
      end

      for _, name in ipairs(require('util.languages').names()) do
        local language = languages[name]
        for _, lsp_server in ipairs(language.lsp_servers or {}) do
          local server
          if type(lsp_server) == 'table' then
            server = lsp_server[1]
            configure(server, lsp_server.enabled, name, language)
          else
            server = lsp_server
            configure(server, nil, name, language)
          end
        end
      end

      -- Servers turned off in `opts.servers` alone, such as `stylua`, which
      -- Mason installs as a formatter and mason-lspconfig would start as a
      -- server
      for server, server_opts in pairs(opts.servers) do
        if
          server_opts == false
          or (type(server_opts) == 'table' and server_opts.enabled == false)
        then
          table.insert(mason_exclude, server)
        end
      end

      -- Off the blocking path: this runs from `BufReadPre`, so until it
      -- returns the file is not on screen, and `scripts/bench-filetypes.lua`
      -- measured it at around a tenth of a second of the first file opened in
      -- a session. Nothing here has to happen before the buffer is drawn --
      -- it enables the servers Mason has already installed, and starts the
      -- installs for the ones it has not -- and `vim.lsp.enable` replays
      -- `FileType` over the buffers that are already open, so a server
      -- enabled a tick late still attaches to this one.
      vim.schedule(
        function()
          require('mason-lspconfig').setup({
            ensure_installed = Plugin.dedup(ensure_installed),
            automatic_enable = { exclude = Plugin.dedup(mason_exclude) },
          })
        end
      )
    end,
  },
}
