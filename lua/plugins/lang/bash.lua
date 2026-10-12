return vim.list_contains(DyNeo.enabled_languages, 'bash')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            bashls = {
              settings = {
                bashIde = {
                  -- nvim-lspconfig ships `*@(...)`, which only matches the
                  -- workspace root, so nothing under `src/`, `lib/` or `bin/`
                  -- ever reaches the index. Restore the recursive pattern that
                  -- bash-language-server itself defaults to. Anything more
                  -- opinionated than this belongs in a project's own
                  -- `.vscode/settings.json`, which codesettings.nvim merges on
                  -- top of these defaults.
                  globPattern = '**/*@(.sh|.inc|.bash|.command)',
                  -- dyshellint runs ShellCheck already, and the shellcheck
                  -- null-ls source offers its fixes; the server's own run
                  -- only listed every finding a second time
                  shellcheckPath = '',
                },
              },
            },
            termuxls = {},
            harper_ls = {},
          },
        },
      },
    }
  or {}
