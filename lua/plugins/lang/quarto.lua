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
        -- The chunks run in iron, whether or not Python is enabled
        dependencies = { 'jmbuhr/otter.nvim', 'Vigemus/iron.nvim' },
        -- On `quarto` only: quarto-nvim activates its runner there alone, and
        -- an R Markdown file's chunks are R.nvim's to run
        -- stylua: ignore
        keys = {
          { '<localleader>c', function() require('quarto.runner').run_cell() end, ft = 'quarto', desc = 'Run Chunk' },
          { '<localleader>a', function() require('quarto.runner').run_above() end, ft = 'quarto', desc = 'Run Chunks Above' },
          { '<localleader>A', function() require('quarto.runner').run_all() end, ft = 'quarto', desc = 'Run All Chunks' },
          { '<localleader>s', function() require('quarto.runner').run_line() end, ft = 'quarto', desc = 'Run Line' },
          { '<localleader>s', function() require('quarto.runner').run_range() end, mode = 'x', ft = 'quarto', desc = 'Run Selection' },
          { '<localleader>p', '<cmd>QuartoPreview<cr>', ft = 'quarto', desc = 'Preview Document' },
        },
        opts = { codeRunner = { default_method = 'iron' } },
      },
    }
  or {}
