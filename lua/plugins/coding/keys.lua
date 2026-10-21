return {
  {
    -- Popup of the keys that can follow the ones typed so far. Other specs
    -- add their groups to `opts.spec`.
    'folke/which-key.nvim',
    event = 'VeryLazy',
    opts_extend = { 'spec' },
    opts = {
      preset = 'helix',
      spec = {
        {
          mode = { 'n', 'x' },
          { '<leader><tab>', group = 'tabs' },
          { '<leader>c', group = 'code' },
          { '<leader>ck', group = 'calls' },
          { '<leader>d', group = 'debug' },
          { '<leader>dp', group = 'profiler' },
          { '<leader>f', group = 'file/find' },
          { '<leader>g', group = 'git' },
          { '<leader>gh', group = 'hunks' },
          { '<leader>i', group = 'infra' },
          { '<leader>D', group = 'data' },
          { '<leader>k', group = 'security' },
          { '<leader>pA', group = 'architecture' },
          { '<leader>pj', group = 'jira' },
          { '<leader>pr', group = 'decision records' },
          { '<leader>pv', group = 'review' },
          { '<leader>q', group = 'quit/session' },
          { '<leader>s', group = 'search' },
          { '<leader>u', group = 'ui' },
          { '<leader>x', group = 'diagnostics/quickfix' },
          { '<leader>y', group = 'yank' },
          { '[', group = 'prev' },
          { ']', group = 'next' },
          { 'g', group = 'goto' },
          { 'gs', group = 'surround' },
          { 'z', group = 'fold' },
          {
            '<leader>b',
            group = 'buffer',
            expand = function() return require('which-key.extras').expand.buf() end,
          },
          {
            '<leader>w',
            group = 'windows',
            proxy = '<c-w>',
            expand = function() return require('which-key.extras').expand.win() end,
          },
          -- better descriptions
          { 'gx', desc = 'Open with system app' },
        },
      },
    },
    keys = {
      {
        '<leader>?',
        function() require('which-key').show({ global = false }) end,
        desc = 'Buffer Keymaps (which-key)',
      },
      {
        '<c-w><space>',
        function() require('which-key').show({ keys = '<c-w>', loop = true }) end,
        desc = 'Window Hydra Mode (which-key)',
      },
    },
  },
}
