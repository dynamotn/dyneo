return {
  {
    -- Render images and diagrams
    'folke/snacks.nvim',
    opts = {
      image = {
        enabled = true,
        backend = 'kitty',
      },
    },
    -- The d2 preview is `tools.diagram.d2.snacks`, mapped from `ftplugin/d2.lua`
  },
  {
    -- Render `:help` pages: headings, tables, code blocks, tags and links
    'OXY2DEV/helpview.nvim',
    -- Its startup work is a dump of every highlight group, on `VimEnter`
    -- and each `ColorScheme`: loaded with the first help page instead, which
    -- it attaches to on the `BufEnter` that follows
    ft = 'help',
    config = function(_, opts)
      local helpview = require('helpview')
      helpview.setup(opts)
      -- `VimEnter` is long gone: its highlight groups are made here
      vim.api.nvim_exec_autocmds('VimEnter', { group = helpview.au })
    end,
  },
}
