return {
  {
    'mason-org/mason.nvim',
    cmd = 'Mason',
    build = ':MasonUpdate',
    -- The packages Mason lacks, read by `lua:dy-mason-registry` below: on
    -- the runtimepath before `setup()`, or mason cannot find the module
    dependencies = {
      { 'dynamotn/mason-registry', dev = true },
    },
    -- Other specs add the tools they need to the list
    opts_extend = { 'ensure_installed' },
    opts = {
      -- Not an option of mason's own: installed by the `config` below
      ensure_installed = {},
      -- Hold a freshly published package back for a week before it may be
      -- installed, the same quarantine `~/.npmrc`, the bun and pnpm
      -- configurations and `uv.toml` apply. mason has no setting for it, so
      -- `tools.mason-quarantine` ages the registry snapshot every package
      -- version is pinned in; see the comment at the top of that module. It
      -- stands alone, asking mason's own providers itself: any provider
      -- listed after it would answer whenever the quarantine fails.
      providers = {
        'tools.mason-quarantine',
      },
      -- Socket Firewall stands between every npm and PyPI install and the
      -- registry, and turns down a package known to be malicious -- the half
      -- of the problem a week of quarantine cannot answer, since a package
      -- can be caught after that week as easily as within it. `sfw` is
      -- installed and updated by Mason itself; swapson already hands it the
      -- installs it routes through bun and uv.
      --
      -- Worth knowing what it does: `sfw` is a local proxy, and the installer
      -- it wraps runs with `NODE_TLS_REJECT_UNAUTHORIZED=0`, trusting the
      -- proxy's certificate instead of the registry's. The verification moves
      -- to `sfw` rather than disappearing, but it does move.
      firewall = {
        enabled = true,
        auto_managed = true,
      },
      -- The first registry with a package wins. `lua:` rather than `file:`,
      -- which is read too slowly to be there for the servers set up at
      -- startup. `tools.mason-registry` holds the tools dytoy installs;
      -- `dy-mason-registry` those installed from a release or a language
      -- registry, until upstream has them.
      registries = {
        'lua:tools.mason-registry',
        'lua:dy-mason-registry',
        'github:mason-org/mason-registry',
      },
    },
    keys = {
      { '<leader>cm', '<cmd>Mason<cr>', desc = 'Mason' },
    },
    ---@param opts MasonSettings|{ ensure_installed: string[] }
    config = function(_, opts)
      require('mason').setup(opts)
      -- swapson routes npm and pip through bun and uv, and only patches mason
      -- once it is itself loaded: as a dependency of nvim-lspconfig alone,
      -- an install from `:Mason` or the dashboard went around it
      if require('util.plugin').has('swapson.nvim') then
        require('lazy').load({ plugins = { 'swapson.nvim' } })
      end
      local mr = require('mason-registry')
      mr:on('package:install:success', function()
        vim.defer_fn(function()
          -- A server installed just now may be wanted by a file on screen,
          -- which is not the current buffer while `:Mason` has the focus.
          -- Every handler runs again: some servers start from an ftplugin.
          local done = {}
          for _, win in ipairs(vim.api.nvim_list_wins()) do
            local buf = vim.api.nvim_win_get_buf(win)
            if
              not done[buf]
              and vim.bo[buf].buftype == ''
              and vim.bo[buf].filetype ~= ''
            then
              done[buf] = true
              vim.api.nvim_buf_call(
                buf,
                function()
                  require('lazy.core.handler.event').trigger({
                    event = 'FileType',
                  })
                end
              )
            end
          end
        end, 100)
      end)

      mr.refresh(function()
        -- Several languages may ask for the same tool, and installing one
        -- twice throws, stopping the rest; nor does an unknown name stop them
        for _, tool in
          ipairs(require('util.plugin').dedup(opts.ensure_installed))
        do
          local ok, p = pcall(mr.get_package, tool)
          if ok and not p:is_installed() and not p:is_installing() then
            p:install()
          end
        end
      end)
    end,
    init = function()
      -- `vale` ships without any style: until `vale sync` has pulled the
      -- packages its config asks for, every run dies on a missing StylesPath,
      -- so the sync follows the install straight away.
      require('util.plugin').on_load('mason.nvim', function()
        require('mason-registry'):on('package:install:success', function(pkg)
          if pkg.name ~= 'vale' then return end
          vim.schedule(function()
            local vale = vim.fn.exepath('vale')
            if vale == '' then return end
            local command = { vale }
            if vim.env.VALE_CONFIG_PATH then
              vim.list_extend(command, { '--config', vim.env.VALE_CONFIG_PATH })
            end
            table.insert(command, 'sync')
            require('util.notify').titled('Mason')(
              'Syncing vale styles',
              vim.log.levels.INFO
            )
            local system = require('util.system')
            system.run(command, { timeout = 5 * 60 * 1000 }, function(result)
              if result.code == 0 then
                require('util.notify').titled('Mason')(
                  'Synced vale styles',
                  vim.log.levels.INFO
                )
              else
                require('util.notify').titled('Mason')(
                  'vale sync failed:\n' .. system.failure(result, 'vale'),
                  vim.log.levels.ERROR
                )
              end
            end)
          end)
        end)
      end)
    end,
  },
}
