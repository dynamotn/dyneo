return {
  {
    -- Hot lines of a profile marked on the code, and its hottest lines and
    -- functions listed; `:DyProfile` records the profile and hands it over
    't-troebst/perfanno.nvim',
    cmd = {
      'PerfLoadFlat',
      'PerfLoadCallGraph',
      'PerfLoadFlameGraph',
      'PerfAnnotate',
      'PerfToggleAnnotations',
      'PerfHottestLines',
      'PerfHottestSymbols',
      'PerfHottestCallersFunction',
      'PerfPickEvent',
      'PerfCycleFormat',
    },
    -- stylua: ignore
    keys = {
      { '<leader>dpr', '<cmd>DyProfile<cr>', desc = 'Profile Program' },
      { '<leader>dpo', '<cmd>DyProfile load<cr>', desc = 'Open Profile' },
      { '<leader>dpg', '<cmd>DyProfile flame<cr>', desc = 'Profile as Flame Graph' },
      { '<leader>dpa', '<cmd>PerfToggleAnnotations<cr>', desc = 'Toggle Profile Annotations' },
      { '<leader>dpf', '<cmd>PerfHottestSymbols<cr>', desc = 'Hottest Functions' },
      { '<leader>dpl', '<cmd>PerfHottestLines<cr>', desc = 'Hottest Lines' },
      { '<leader>dpc', '<cmd>PerfHottestCallersFunction<cr>', desc = 'Hottest Callers' },
    },
    -- The pickers fall back to `vim.ui.select`, which is snacks' picker
    opts = {
      telescope = { enabled = false },
      fzf_lua = { enabled = false },
    },
  },
}
