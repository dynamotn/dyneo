return {
  {
    -- Jump anywhere on screen by a label shown at the end of each match
    'folke/flash.nvim',
    event = 'VeryLazy',
    vscode = true,
    ---@type Flash.Config
    opts = {},
    -- stylua: ignore
    keys = {
      { 's', mode = { 'n', 'x', 'o' }, function() require('flash').jump() end, desc = 'Flash' },
      { 'S', mode = { 'n', 'o', 'x' }, function() require('flash').treesitter() end, desc = 'Flash Treesitter' },
      { 'r', mode = 'o', function() require('flash').remote() end, desc = 'Remote Flash' },
      { 'R', mode = { 'o', 'x' }, function() require('flash').treesitter_search() end, desc = 'Treesitter Search' },
      -- `<C-s>` is the zellij prefix and never reaches Neovim
      { '<M-s>', mode = { 'c' }, function() require('flash').toggle() end, desc = 'Toggle Flash Search' },
      -- Incremental selection by treesitter node
      { '<c-space>', mode = { 'n', 'o', 'x' },
        function()
          require('flash').treesitter({
            actions = {
              ['<c-space>'] = 'next',
              ['<BS>'] = 'prev',
            },
          })
        end, desc = 'Treesitter Incremental Selection' },
    },
  },
  {
    -- Move between, resize and swap windows, past the edge into tmux/zellij
    -- panes
    --
    -- zellij's `nvim-navigator` plugin tells a Neovim pane by the command it
    -- runs and hands it `Shift-<Arrow>`; at the edge of Neovim these keys
    -- carry on into the next pane, or tab, of the multiplexer.
    'mrjones2014/smart-splits.nvim',
    keys = {
      {
        '<S-Left>',
        function() require('smart-splits').move_cursor_left() end,
        desc = 'Navigate to left window',
        mode = { 'n', 't' },
      },
      {
        '<S-Down>',
        function() require('smart-splits').move_cursor_down() end,
        desc = 'Navigate to down window',
        mode = { 'n', 't' },
      },
      {
        '<S-Up>',
        function() require('smart-splits').move_cursor_up() end,
        desc = 'Navigate to up window',
        mode = { 'n', 't' },
      },
      {
        '<S-Right>',
        function() require('smart-splits').move_cursor_right() end,
        desc = 'Navigate to right window',
        mode = { 'n', 't' },
      },
      {
        '<C-\\>',
        function() require('smart-splits').move_cursor_previous() end,
        desc = 'Navigate to previous window',
        -- Not in a terminal, where `<C-\><C-n>` leaves terminal mode
        mode = 'n',
      },
      -- Resize past Neovim's own edge, into the multiplexer's panes
      {
        '<C-Up>',
        function() require('smart-splits').resize_up() end,
        desc = 'Resize window up',
      },
      {
        '<C-Down>',
        function() require('smart-splits').resize_down() end,
        desc = 'Resize window down',
      },
      {
        '<C-Left>',
        function() require('smart-splits').resize_left() end,
        desc = 'Resize window left',
      },
      {
        '<C-Right>',
        function() require('smart-splits').resize_right() end,
        desc = 'Resize window right',
      },
      -- `<C-w><Arrow>` is `<C-w>hjkl` again, so the arrows under the window
      -- group are free to swap instead
      {
        '<leader>w<Up>',
        function() require('smart-splits').swap_buf_up() end,
        desc = 'Swap buffer up',
      },
      {
        '<leader>w<Down>',
        function() require('smart-splits').swap_buf_down() end,
        desc = 'Swap buffer down',
      },
      {
        '<leader>w<Left>',
        function() require('smart-splits').swap_buf_left() end,
        desc = 'Swap buffer left',
      },
      {
        '<leader>w<Right>',
        function() require('smart-splits').swap_buf_right() end,
        desc = 'Swap buffer right',
      },
    },
    opts = {
      -- Stop at the last window when there is no pane beyond, rather than
      -- wrapping round to the first
      at_edge = 'stop',
      -- zellij binds `Shift-Left`/`Shift-Right` to `MoveFocusOrTab`, so going
      -- past its last pane moves on to the next tab, from Neovim as well
      zellij_move_focus_or_tab = true,
      -- Keep editing the buffer that was moved, not the one it landed on
      cursor_follows_swapped_bufs = true,
      -- Only the multiplexers there is a pane to resize in. Left to detect on
      -- its own, it also picks kitty and wezterm, whose remote control is not
      -- set up for it here.
      multiplexer_integration = vim.env.ZELLIJ and 'zellij'
        or vim.env.TMUX and 'tmux'
        or false,
    },
  },
  {
    -- Editable quickfix with context lines
    'stevearc/quicker.nvim',
    ft = 'qf',
    -- Toggle the lists, focusing them as they open
    keys = {
      {
        '<leader>xq',
        function() require('quicker').toggle({ focus = true }) end,
        desc = 'Quickfix List',
      },
      {
        '<leader>xl',
        function() require('quicker').toggle({ focus = true, loclist = true }) end,
        desc = 'Location List',
      },
    },
    opts = {
      keys = {
        {
          '>',
          function()
            require('quicker').expand({
              before = 2,
              after = 2,
              add_to_existing = true,
            })
          end,
          desc = 'Expand quickfix context',
        },
        {
          '<',
          function() require('quicker').collapse() end,
          desc = 'Collapse quickfix context',
        },
      },
    },
  },
}
