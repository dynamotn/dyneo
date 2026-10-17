local language = require('config.languages').markdown
local cmp_util = require('util.cmp')

local obsidian_wanted = DyNeo.used_full_plugins
  or DyNeo.enabled_plugins.obsidian
--- The vaults that exist on this machine, asked only when obsidian.nvim is
--- wanted at all
local obsidian_vaults = obsidian_wanted
    and vim.tbl_filter(
      function(vault) return vim.fn.isdirectory(vault.path) == 1 end,
      DyNeo.obsidian.vaults()
    )
  or {}
-- A note being read or created in a vault loads obsidian.nvim; any other
-- Markdown file leaves it be. `*` crosses folders in an autocmd pattern.
local obsidian_events = {} ---@type string[]
for _, vault in ipairs(obsidian_vaults) do
  local pattern = vim.fs.normalize(vault.path):gsub('[,*?{}%[%]\\]', '\\%0')
    .. '/*.md'
  vim.list_extend(
    obsidian_events,
    { 'BufReadPre ' .. pattern, 'BufNewFile ' .. pattern }
  )
end

return vim.list_contains(DyNeo.enabled_languages, 'markdown')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            marksman = {},
            harper_ls = {},
          },
        },
      },
      {
        -- Preview markdown
        -- No `ft`: the key below is already limited to these filetypes and
        -- loads the plugin, which has nothing else to set up. Loading on `ft`
        -- made lazy.nvim replay `FileType` on every Markdown buffer, sourcing
        -- its ftplugins and syntax files and starting its servers twice.
        'toppair/peek.nvim',
        build = 'deno task --quiet build:fast',
        enabled = DyNeo.used_full_plugins or vim.fn.executable('deno') == 1,
        keys = {
          {
            '<leader>cp',
            function() require('peek').open() end,
            ft = language.filetypes,
            desc = 'Markdown Preview',
          },
        },
        opts = {
          app = 'browser',
        },
      },
      {
        -- Obsidian
        'obsidian-nvim/obsidian.nvim',
        event = obsidian_events,
        enabled = #obsidian_vaults > 0,
        opts = {
          workspaces = obsidian_vaults,
          ui = { enable = false },
          legacy_commands = false,
        },
        -- stylua: ignore
        keys = {
          { '<localleader>o', '', desc = '+obsidian', ft = language.filetypes },
          { '<localleader>on', '<cmd>Obsidian new<cr>', desc = 'New Note', ft = language.filetypes },
          { '<localleader>oo', '<cmd>Obsidian quick_switch<cr>', desc = 'Quick Switch', ft = language.filetypes },
          { '<localleader>os', '<cmd>Obsidian search<cr>', desc = 'Search Notes', ft = language.filetypes },
          { '<localleader>ob', '<cmd>Obsidian backlinks<cr>', desc = 'Backlinks', ft = language.filetypes },
          { '<localleader>ot', '<cmd>Obsidian today<cr>', desc = 'Today', ft = language.filetypes },
          { '<localleader>oT', '<cmd>Obsidian template<cr>', desc = 'Insert Template', ft = language.filetypes },
        },
        init = function()
          DyNeo.completion_sources =
            vim.tbl_extend('force', DyNeo.completion_sources, {
              obsidian = '「NOTE」',
            })
        end,
      },
      {
        -- Completion. obsidian.nvim loads on its own filetypes, not as a
        -- dependency: a dependency loads with blink.cmp on the first
        -- `InsertEnter` of any buffer.
        'blink.cmp',
        opts = {
          sources = {
            -- Not need to have compat for obsidian.nvim, because it is already handled in obsidian.nvim
            -- compat = { 'obsidian' },
            per_filetype = {
              markdown = cmp_util.sources('markdown'),
            },
          },
        },
      },
      {
        -- Todo notes
        'folke/snacks.nvim',
        keys = {
          {
            '<leader>T',
            function()
              ---@diagnostic disable-next-line: missing-fields
              Snacks.scratch({
                icon = ' ',
                name = 'Todo',
                ft = 'markdown',
                file = DyNeo.obsidian.todo_path(),
              })
            end,
            desc = 'Todo List',
          },
        },
      },
      {
        -- Linter config
        'mfussenegger/nvim-lint',
        opts = function()
          local lint = require('lint')
          -- nvim-lint runs the linter without a shell, so a `~` would reach
          -- it verbatim, and a `--config` naming a missing file is fatal to
          -- markdownlint-cli2. The shared config is only passed when present.
          local config = vim.fs.joinpath(
            vim.env.XDG_CONFIG_HOME or vim.fn.expand('~/.config'),
            'markdownlint',
            'config.yaml'
          )
          if vim.fn.filereadable(config) == 1 then
            -- `-` is the default argument being replaced: without it the
            -- buffer sent on stdin is never linted and only the usage prints
            lint.linters['markdownlint-cli2'].args = { '--config', config, '-' }
          end
        end,
      },
    }
  or {}
