return {
  {
    -- Improve messages, cmdline, popups & LSP
    'folke/noice.nvim',
    event = 'VeryLazy',
    opts = {
      lsp = {
        override = {
          ['vim.lsp.util.convert_input_to_markdown_lines'] = true,
          ['vim.lsp.util.stylize_markdown'] = true,
          ['cmp.entry.get_documentation'] = true,
        },
      },
      routes = {
        {
          filter = {
            event = 'notify',
            find = 'No information available',
          },
          opts = {
            skip = true,
          },
        },
        {
          filter = {
            event = 'notify',
            find = 'split buf',
          },
          opts = {
            skip = true,
          },
        },
        {
          -- Write, undo and redo messages in the mini view
          filter = {
            event = 'msg_show',
            any = {
              { find = '%d+L, %d+B' },
              { find = '; after #%d+' },
              { find = '; before #%d+' },
            },
          },
          view = 'mini',
        },
      },
      presets = {
        bottom_search = false,
        command_palette = true,
        long_message_to_split = true,
        lsp_doc_border = true,
      },
    },
    -- stylua: ignore
    keys = {
      { '<leader>sn', '', desc = '+noice' },
      { '<S-Enter>', function() require('noice').redirect(vim.fn.getcmdline()) end, mode = 'c', desc = 'Redirect Cmdline' },
      { '<leader>snl', function() require('noice').cmd('last') end, desc = 'Noice Last Message' },
      { '<leader>snh', function() require('noice').cmd('history') end, desc = 'Noice History' },
      { '<leader>sna', function() require('noice').cmd('all') end, desc = 'Noice All' },
      { '<leader>snd', function() require('noice').cmd('dismiss') end, desc = 'Dismiss All' },
      { '<leader>snt', function() require('noice').cmd('pick') end, desc = 'Noice Picker' },
      { '<c-f>', function() if not require('noice.lsp').scroll(4) then return '<c-f>' end end, silent = true, expr = true, desc = 'Scroll Forward', mode = { 'i', 'n', 's' } },
      { '<c-b>', function() if not require('noice.lsp').scroll(-4) then return '<c-b>' end end, silent = true, expr = true, desc = 'Scroll Backward', mode = { 'i', 'n', 's' } },
    },
    config = function(_, opts)
      -- noice replays the messages from before it loaded; while Lazy is
      -- installing plugins those are only noise
      if vim.o.filetype == 'lazy' then vim.cmd([[messages clear]]) end
      require('noice').setup(opts)
    end,
  },
  {
    -- Windows layout: panels docked to the edges of the editor
    'folke/edgy.nvim',
    event = 'VeryLazy',
    keys = {
      {
        '<leader>ue',
        function() require('edgy').toggle() end,
        desc = 'Edgy Toggle',
      },
      -- stylua: ignore
      { '<leader>uE', function() require('edgy').select() end, desc = 'Edgy Select Window' },
    },
    opts = function()
      local opts = {
        bottom = {
          {
            ft = 'toggleterm',
            size = { height = 0.4 },
            filter = function(_, win)
              return vim.api.nvim_win_get_config(win).relative == ''
            end,
          },
          {
            ft = 'noice',
            size = { height = 0.4 },
            filter = function(_, win)
              return vim.api.nvim_win_get_config(win).relative == ''
            end,
          },
          'Trouble',
          { ft = 'qf', title = 'QuickFix' },
          {
            ft = 'help',
            size = { height = 20 },
            -- Not a help file open for editing
            filter = function(buf) return vim.bo[buf].buftype == 'help' end,
          },
          {
            title = 'Neotest Output',
            ft = 'neotest-output-panel',
            size = { height = 15 },
          },
        },
        left = {
          { title = 'Neotest Summary', ft = 'neotest-summary' },
        },
        -- Avante is not here: it lays out and resizes its own stack of
        -- windows, which edgy would split into separate panels
        right = {
          { title = 'Grug Far', ft = 'grug-far', size = { width = 0.4 } },
        },
        keys = {
          ['<c-Right>'] = function(win) win:resize('width', 2) end,
          ['<c-Left>'] = function(win) win:resize('width', -2) end,
          ['<c-Up>'] = function(win) win:resize('height', 2) end,
          ['<c-Down>'] = function(win) win:resize('height', -2) end,
        },
      }

      -- Trouble and Snacks terminals split against an edge of the editor
      for _, pos in ipairs({ 'top', 'bottom', 'left', 'right' }) do
        opts[pos] = opts[pos] or {}
        table.insert(opts[pos], {
          ft = 'trouble',
          filter = function(_, win)
            return vim.w[win].trouble
              and vim.w[win].trouble.position == pos
              and vim.w[win].trouble.type == 'split'
              and vim.w[win].trouble.relative == 'editor'
              and not vim.w[win].trouble_preview
          end,
        })
      end
      for _, pos in ipairs({ 'top', 'bottom', 'left', 'right' }) do
        table.insert(opts[pos], {
          ft = 'snacks_terminal',
          size = { height = 0.4 },
          title = '%{b:snacks_terminal.id}: %{b:term_title}',
          filter = function(_, win)
            return vim.w[win].snacks_win
              and vim.w[win].snacks_win.position == pos
              and vim.w[win].snacks_win.relative == 'editor'
              and not vim.w[win].trouble_preview
          end,
        })
      end
      return opts
    end,
  },
  {
    -- Leave room in the buffer line for edgy's sidebars
    'akinsho/bufferline.nvim',
    optional = true,
    opts = function()
      local Offset = require('bufferline.offset')
      if Offset.edgy then return end
      local get = Offset.get
      Offset.get = function()
        if package.loaded.edgy then
          local old_offset = get()
          local layout = require('edgy.config').layout
          local ret = { left = '', left_size = 0, right = '', right_size = 0 }
          for _, pos in ipairs({ 'left', 'right' }) do
            local sb = layout[pos]
            if sb and #sb.wins > 0 then
              local title = ' Sidebar' .. string.rep(' ', sb.bounds.width - 8)
              ret[pos] = old_offset[pos .. '_size'] > 0 and old_offset[pos]
                or pos == 'left' and ('%#Bold#' .. title .. '%*' .. '%#BufferLineOffsetSeparator#│%*')
                or pos == 'right'
                  and ('%#BufferLineOffsetSeparator#│%*' .. '%#Bold#' .. title .. '%*')
              ret[pos .. '_size'] = old_offset[pos .. '_size'] > 0
                  and old_offset[pos .. '_size']
                or sb.bounds.width
            end
          end
          ret.total_size = ret.left_size + ret.right_size
          if ret.total_size > 0 then return ret end
        end
        return get()
      end
      Offset.edgy = true
    end,
  },
}
