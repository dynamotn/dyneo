local language = require('config.languages').blade
local cmp_util = require('util.cmp')

-- Laravel's tooling reaches across the whole project, not just the templates:
-- its keys are set on PHP buffers too, and the PHP buffers of a Laravel
-- project load it (see `init` below)
local filetypes = vim.list_extend(vim.deepcopy(language.filetypes), { 'php' })

return vim.list_contains(DyNeo.enabled_languages, 'blade')
    and {
      {
        -- Artisan, routes, views and the rest of the project, as pickers
        'adalessa/laravel.nvim',
        cmd = 'Laravel',
        -- A Blade buffer loads both plugins, and a PHP buffer only inside a
        -- Laravel project, one with `artisan` at its root; any other PHP file
        -- leaves them be. Laravel runs `artisan` as it loads and on
        -- `BufEnter`, so a buffer under a held directory loads nothing until
        -- the directory is let go.
        init = function()
          local group =
            vim.api.nvim_create_augroup('dyneo_laravel', { clear = true })
          local loaded = false
          ---@param bufnr integer
          local function load(bufnr)
            local filetype = vim.bo[bufnr].filetype
            if not vim.list_contains(filetypes, filetype) then return end
            if filetype == 'php' and not vim.fs.root(bufnr, 'artisan') then
              return
            end
            if require('util.untrusted').held(bufnr) then return end
            pcall(vim.api.nvim_del_augroup_by_id, group)
            if not loaded then
              loaded = true
              require('lazy').load({
                plugins = { 'laravel.nvim', 'blade-nav.nvim' },
              })
            end
            -- Their ftplugins, which this buffer has missed: the
            -- `filetypeplugin` group only, not every `FileType` handler
            vim.api.nvim_buf_call(
              bufnr,
              function()
                pcall(
                  vim.api.nvim_exec_autocmds,
                  'FileType',
                  { group = 'filetypeplugin', pattern = filetype }
                )
              end
            )
          end
          vim.api.nvim_create_autocmd('FileType', {
            group = group,
            pattern = filetypes,
            callback = function(args) load(args.buf) end,
          })
          require('util.untrusted').on_release('laravel', load)
        end,
        dependencies = {
          'MunifTanjim/nui.nvim',
          'nvim-lua/plenary.nvim',
          'nvim-neotest/nvim-nio',
        },
        opts = {
          features = {
            pickers = { provider = 'snacks' },
          },
        },
        -- Only where Laravel is: elsewhere `<localleader>l` is Octo's labels
        keys = {
          { '<localleader>l', '', desc = '+laravel', ft = filetypes },
          {
            '<localleader>ll',
            function() Laravel.pickers.laravel() end,
            desc = 'Laravel picker',
            ft = filetypes,
          },
          {
            '<localleader>la',
            function() Laravel.pickers.artisan() end,
            desc = 'Artisan picker',
            ft = filetypes,
          },
          {
            '<localleader>lr',
            function() Laravel.pickers.routes() end,
            desc = 'Routes picker',
            ft = filetypes,
          },
          {
            '<localleader>lm',
            function() Laravel.pickers.make() end,
            desc = 'Make picker',
            ft = filetypes,
          },
          {
            '<localleader>lc',
            function() Laravel.pickers.commands() end,
            desc = 'Commands picker',
            ft = filetypes,
          },
          {
            '<localleader>lo',
            function() Laravel.pickers.resources() end,
            desc = 'Resources picker',
            ft = filetypes,
          },
          {
            '<localleader>lh',
            function() Laravel.run('artisan docs') end,
            desc = 'Laravel documentation',
            ft = filetypes,
          },
        },
      },
      {
        -- `gf` on a view name, a route or a component
        'ricardoramirezr/blade-nav.nvim',
        -- Kept off the `blink.cmp` spec: lazy.nvim keeps a single `init` per
        -- plugin, and this one would replace the labels set in completion.lua
        init = function()
          DyNeo.completion_sources =
            vim.tbl_extend('force', DyNeo.completion_sources, {
              ['blade-nav'] = '「BLADE」',
              laravel = '「LARAVEL」',
            })
        end,
      },
      {
        -- Completion for view names and Laravel's own symbols. Both plugins
        -- load on their own filetypes, not as dependencies: a dependency
        -- loads with blink.cmp on the first `InsertEnter` of any buffer.
        'blink.cmp',
        opts = {
          sources = {
            compat = { 'laravel' },
            per_filetype = {
              blade = cmp_util.sources('blade'),
            },
            providers = {
              ['blade-nav'] = {
                name = 'blade-nav',
                -- ships a blink source of its own, so no compat shim
                module = 'blade-nav.integrations.blink',
              },
              laravel = {
                name = 'laravel',
                module = 'blink.compat.source',
                score_offset = 95,
              },
            },
          },
        },
      },
    }
  or {}
