return {
  'dynamotn/blink-cmp-fuzzy-path', -- Fuzzy path source
  'mikavilpas/blink-ripgrep.nvim', -- Ripgrep
  'Kaiser-Yang/blink-cmp-dictionary', -- Dictionary source
  'hrsh7th/cmp-calc', -- Math calculation
  {
    -- Tmux source. The fork reads panes in the background instead of on
    -- every key; back to mgalliou/blink-cmp-tmux once its #3 is merged.
    'dynamotn/blink-cmp-tmux',
    commit = '9787c9f981bd5c7a2b732d2e20505d67a10dfde6',
  },
  'dynamotn/blink-cmp-zellij', -- Zellij source
  'dynamotn/blink-cmp-kitty', -- Kitty source
  'moyiz/blink-emoji.nvim', -- Emoji source
  'MahanRahmati/blink-nerdfont.nvim', -- Nerdfont source
  {
    -- Dynamic source
    'uga-rosa/cmp-dynamic',
    config = function()
      require('cmp_dynamic').register({
        {
          label = 'today',
          insertText = function() return os.date('%d/%m/%Y') end,
        },
        {
          label = 'today',
          insertText = function() return os.date('%Y/%m/%d') end,
        },
        {
          label = 'now',
          insertText = function() return os.date('%H:%M:%S %d/%m/%Y') end,
        },
        {
          label = 'now',
          insertText = function() return os.date('%Y_%m_%d_%H_%M') end,
        },
        {
          label = 'timestamp',
          insertText = function() return os.date('%s') end,
        },
      })
    end,
  },
  {
    -- Engine for completion
    'saghen/blink.cmp',
    version = '*',
    event = { 'InsertEnter', 'CmdlineEnter' },
    -- Lists other specs add to rather than replace. `sources.compat` names
    -- nvim-cmp sources to run through blink.compat.
    opts_extend = {
      'sources.completion.enabled_providers',
      'sources.compat',
      'sources.default',
    },
    dependencies = {
      'rafamadriz/friendly-snippets',
      { 'saghen/blink.compat', version = '*', opts = {} },
      'onsails/lspkind.nvim', -- pictograms
      'blink-cmp-fuzzy-path',
      'blink-cmp-dictionary',
      'cmp-calc',
      'blink-cmp-tmux',
      'blink-cmp-zellij',
      'blink-cmp-kitty',
      'cmp-dynamic',
      'blink-ripgrep.nvim',
      'blink-emoji.nvim',
      'blink-nerdfont.nvim',
    },
    ---@module 'blink.cmp'
    ---@type blink.cmp.Config|{ sources: { compat: string[] } }
    opts = {
      snippets = { preset = 'default' },
      appearance = {
        nerd_font_variant = 'mono',
        kind_icons = require('config.defaults').icons.kinds,
      },
      keymap = {
        preset = 'enter',
        ['<C-y>'] = { 'select_and_accept' },
        ['<Tab>'] = {
          function()
            return require('util.cmp').map({
              'snippet_forward',
              'ai_nes',
              'ai_accept',
            })()
          end,
          'fallback',
        },
      },
      sources = {
        -- compatible sources from nvim-cmp
        compat = { 'calc', 'dynamic' },
        providers = {
          -- self download dictionaries
          dictionary = {
            module = 'blink-cmp-dictionary',
            name = 'dictionary',
            min_keyword_length = 3,
            score_offset = -20,
            opts = {
              dictionary_directories = {
                vim.fn.expand(DyNeo.dictionaries_path),
              },
            },
          },
          -- tmux panes
          tmux = {
            module = 'blink-cmp-tmux',
            name = 'tmux',
            opts = { panes = 'session' },
          },
          -- zellij panes
          zellij = {
            module = 'blink-cmp-zellij',
            name = 'zellij',
            opts = { all_panes = true },
          },
          -- kitty windows
          kitty = {
            module = 'blink-cmp-kitty',
            name = 'kitty',
          },
          -- ripgrep all files in folder
          ripgrep = {
            module = 'blink-ripgrep',
            name = 'ripgrep',
          },
          emoji = {
            module = 'blink-emoji',
            name = 'emoji',
            score_offset = 21,
            opts = { insert = true },
          },
          nerdfont = {
            module = 'blink-nerdfont',
            name = 'nerdfont',
            score_offset = 22,
            opts = { insert = true },
          },
          -- text from all buffers
          buffer = {
            opts = {
              get_bufnrs = function()
                local bufs = {}
                for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
                  if vim.bo[bufnr].buftype == '' then
                    table.insert(bufs, bufnr)
                  end
                end
                return bufs
              end,
            },
            score_offset = 18,
          },
          -- path with start point from root of project, not current folder
          project_path = {
            module = 'blink.cmp.sources.path',
            name = 'project_path',
            opts = {
              get_cwd = function(_) return require('util.root').get() end,
            },
          },
          fuzzy_path = {
            module = 'blink-cmp-fuzzy-path',
            name = 'fuzzy_path',
            score_offset = 0,
            min_keyword_length = 1,
          },
          lsp = {
            score_offset = 20,
          },
          snippets = {
            score_offset = 19,
          },
          cmdline = {
            score_offset = 20,
          },
        },
        default = function() return require('util.cmp').setup_default_sources() end,
        per_filetype = {},
      },
      -- No typos allowed, as fzf does; blink's default forgives one for every
      -- four characters typed
      fuzzy = {
        max_typos = function() return 0 end,
      },
      -- show signature of LSP function...
      signature = { enabled = true },
      -- completion for command line
      cmdline = {
        enabled = true,
        keymap = {
          -- tab for only select
          ['<Tab>'] = {
            'show_and_insert',
            'select_next',
          },
          -- auto accept ghost text by Right key
          ['<Right>'] = {
            function(cmp)
              if cmp.is_ghost_text_visible() then return cmp.accept() end
            end,
            'fallback',
          },
          -- only use Left for move cursor
          ['<Left>'] = {
            'fallback',
          },
        },
        -- need to auto show completion menu
        completion = {
          list = { selection = { preselect = false } },
          menu = {
            auto_show = true,
          },
          ghost_text = { enabled = true },
        },
        sources = function() return require('util.cmp').cmdline_sources() end,
      },
      completion = {
        accept = { auto_brackets = { enabled = true } },
        documentation = {
          auto_show = true,
          auto_show_delay_ms = 200,
          window = { border = 'rounded' },
        },
        ghost_text = { enabled = vim.g.ai_cmp },
        menu = {
          border = 'rounded',
          draw = {
            treesitter = { 'lsp' },
            columns = {
              { 'source_name', 'kind_icon' },
              { 'label', 'label_description', gap = 1 },
            },
            components = {
              kind_icon = {
                ellipsis = false,
                text = function(ctx)
                  local icon = ctx.kind_icon
                  local kind_icons = require('config.defaults').icons.kinds
                  -- Show icon of file when source is Path
                  if
                    vim.tbl_contains(
                      { 'Path', 'project_path', 'fuzzy_path' },
                      ctx.source_name
                    )
                  then
                    local dev_icon, _ =
                      require('nvim-web-devicons').get_icon(ctx.label)
                    if dev_icon then icon = dev_icon end
                  else
                    if kind_icons[ctx.source_name] then
                      icon = kind_icons[ctx.source_name]
                    else
                      icon = require('lspkind').symbol_map[ctx.kind] or ''
                    end
                  end

                  return icon .. ctx.icon_gap
                end,

                -- The kind's group, which blink swaps for the colour itself on
                -- a Tailwind class, or the file's devicon group on a path
                highlight = function(ctx)
                  local hl = ctx.kind_hl
                  if
                    vim.tbl_contains(
                      { 'Path', 'project_path', 'fuzzy_path' },
                      ctx.source_name
                    )
                  then
                    local dev_icon, dev_hl =
                      require('nvim-web-devicons').get_icon(ctx.label)
                    if dev_icon then hl = dev_hl end
                  end
                  return hl
                end,
              },
              source_name = {
                text = function(ctx)
                  if
                    vim.tbl_contains({ 'Path', 'fuzzy_path' }, ctx.source_name)
                  then
                    return DyNeo.completion_sources['Path']
                  end
                  return DyNeo.completion_sources[ctx.source_name]
                    or ctx.source_name
                end,
              },
            },
          },
        },
      },
    },
    ---@param opts blink.cmp.Config|{ sources: { compat: string[] } }
    config = function(_, opts)
      if opts.snippets and opts.snippets.preset == 'default' then
        opts.snippets.expand = require('util.cmp').expand
      end
      -- Run the nvim-cmp sources named in `compat` through blink.compat
      local enabled = opts.sources.default
      for _, source in ipairs(opts.sources.compat or {}) do
        opts.sources.providers[source] = vim.tbl_deep_extend(
          'force',
          { name = source, module = 'blink.compat.source' },
          opts.sources.providers[source] or {}
        )
        if
          type(enabled) == 'table' and not vim.tbl_contains(enabled, source)
        then
          table.insert(enabled, source)
        end
      end
      -- Not an option of blink's own, which would reject it
      opts.sources.compat = nil

      -- A provider's `kind` adds a completion item kind of its own
      for _, provider in pairs(opts.sources.providers or {}) do
        ---@cast provider blink.cmp.SourceProviderConfig|{ kind?: string }
        if provider.kind then
          local CompletionItemKind =
            require('blink.cmp.types').CompletionItemKind
          local kind_idx = #CompletionItemKind + 1
          CompletionItemKind[kind_idx] = provider.kind
          CompletionItemKind[provider.kind] = kind_idx

          local transform_items = provider.transform_items
          provider.transform_items = function(ctx, items)
            items = transform_items and transform_items(ctx, items) or items
            for _, item in ipairs(items) do
              item.kind = kind_idx or item.kind
              item.kind_icon = require('config.defaults').icons.kinds[item.kind_name]
                or item.kind_icon
                or nil
            end
            return items
          end
          provider.kind = nil
        end
      end

      require('blink.cmp').setup(opts)
    end,
    init = function()
      DyNeo.completion_sources =
        vim.tbl_extend('force', DyNeo.completion_sources, {
          Path = '「PATH」',
          project_path = '「PROJ」',
          Snippets = '「SNIP」',
          LSP = '「LSP」',
          Buffer = '「BUF」',
          ripgrep = '「FILE」',
          dictionary = '「DICT」',
          calc = '「CALC」',
          tmux = '「MUX」',
          zellij = '「MUX」',
          kitty = '「TERM」',
          dynamic = '「MISC」',
          Cmdline = '「CMD」',
          emoji = '「EMOJI」',
          nerdfont = '「NERD」',
        })
    end,
  },
  {
    'catppuccin',
    optional = true,
    opts = { integrations = { blink_cmp = true } },
  },
  {
    -- Name the group of `plugin/spell.lua` adding words to my word lists
    'folke/which-key.nvim',
    opts = {
      spec = {
        { '<leader>z', group = 'dictionary', mode = { 'n', 'x' } },
      },
    },
  },
}
