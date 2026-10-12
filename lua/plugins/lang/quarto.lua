local language = require('config.languages').quarto

return vim.list_contains(DyNeo.enabled_languages, 'quarto')
    and {
      {
        -- Quarto and R Markdown: language servers inside the `{python}`,
        -- `{r}` chunks through otter, which it activates with a query for
        -- those braces, and the chunks run in iron's REPL of their language
        'quarto-dev/quarto-nvim',
        -- Its runner reads the chunks off otter, so it goes where otter goes
        enabled = DyNeo.used_full_plugins or DyNeo.enabled_plugins.otter,
        ft = language.filetypes,
        cmd = { 'QuartoPreview', 'QuartoActivate' },
        dependencies = { 'jmbuhr/otter.nvim' },
        -- stylua: ignore
        keys = {
          { '<localleader>c', function() require('quarto.runner').run_cell() end, ft = language.filetypes, desc = 'Run Chunk' },
          { '<localleader>a', function() require('quarto.runner').run_above() end, ft = language.filetypes, desc = 'Run Chunks Above' },
          { '<localleader>A', function() require('quarto.runner').run_all() end, ft = language.filetypes, desc = 'Run All Chunks' },
          { '<localleader>s', function() require('quarto.runner').run_line() end, ft = language.filetypes, desc = 'Run Line' },
          { '<localleader>s', function() require('quarto.runner').run_range() end, mode = 'x', ft = language.filetypes, desc = 'Run Selection' },
          { '<localleader>p', '<cmd>QuartoPreview<cr>', ft = language.filetypes, desc = 'Preview Document' },
        },
        opts = { codeRunner = { default_method = 'iron' } },
      },
    }
  or {}
