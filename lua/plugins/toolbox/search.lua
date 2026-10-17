return {
  {
    -- Search and replace across files
    'MagicDuck/grug-far.nvim',
    opts = { headerMaxWidth = 80 },
    cmd = { 'GrugFar', 'GrugFarWithin' },
    keys = {
      {
        '<leader>sr',
        function()
          local grug = require('grug-far')
          local ext = vim.bo.buftype == '' and vim.fn.expand('%:e')
          grug.open({
            transient = true,
            prefills = {
              filesFilter = ext and ext ~= '' and '*.' .. ext or nil,
            },
          })
        end,
        mode = { 'n', 'x' },
        desc = 'Search and Replace',
      },
      {
        '<leader>sf',
        function()
          require('grug-far').open({
            transient = true,
            prefills = { paths = vim.fn.expand('%') },
          })
        end,
        desc = 'Search and Replace (File)',
      },
    },
  },
  {
    -- Lists of diagnostics, symbols, references, quickfix and location
    'folke/trouble.nvim',
    cmd = { 'Trouble' },
    opts = {
      modes = {
        lsp = {
          win = { position = 'right' },
        },
      },
    },
    keys = {
      {
        '<leader>xx',
        '<cmd>Trouble diagnostics toggle<cr>',
        desc = 'Diagnostics (Trouble)',
      },
      {
        '<leader>xX',
        '<cmd>Trouble diagnostics toggle filter.buf=0<cr>',
        desc = 'Buffer Diagnostics (Trouble)',
      },
      -- `<leader>cs` belongs to the outline, see `plugins.lsp.outline`
      {
        '<leader>cS',
        '<cmd>Trouble lsp toggle<cr>',
        desc = 'LSP references/definitions/... (Trouble)',
      },
      {
        '<leader>xL',
        '<cmd>Trouble loclist toggle<cr>',
        desc = 'Location List (Trouble)',
      },
      {
        '<leader>xQ',
        '<cmd>Trouble qflist toggle<cr>',
        desc = 'Quickfix List (Trouble)',
      },
      {
        '[q',
        function()
          if require('trouble').is_open() then
            require('trouble').prev({ skip_groups = true, jump = true })
          else
            local ok, err = pcall(vim.cmd.cprev)
            if not ok then vim.notify(err, vim.log.levels.ERROR) end
          end
        end,
        desc = 'Previous Trouble/Quickfix Item',
      },
      {
        ']q',
        function()
          if require('trouble').is_open() then
            require('trouble').next({ skip_groups = true, jump = true })
          else
            local ok, err = pcall(vim.cmd.cnext)
            if not ok then vim.notify(err, vim.log.levels.ERROR) end
          end
        end,
        desc = 'Next Trouble/Quickfix Item',
      },
    },
  },
  {
    -- TODO, HACK, BUG... comments, highlighted and listed
    'folke/todo-comments.nvim',
    cmd = { 'TodoTrouble' },
    event = 'LazyFile',
    opts = {},
    -- stylua: ignore
    keys = {
      { ']t', function() require('todo-comments').jump_next() end, desc = 'Next Todo Comment' },
      { '[t', function() require('todo-comments').jump_prev() end, desc = 'Previous Todo Comment' },
      { '<leader>xt', '<cmd>Trouble todo toggle<cr>', desc = 'Todo (Trouble)' },
      { '<leader>xT', '<cmd>Trouble todo toggle filter = {tag = {TODO,FIX,FIXME}}<cr>', desc = 'Todo/Fix/Fixme (Trouble)' },
      { '<leader>st', function() Snacks.picker.todo_comments() end, desc = 'Todo' },
      { '<leader>sT', function() Snacks.picker.todo_comments({ keywords = { 'TODO', 'FIX', 'FIXME' } }) end, desc = 'Todo/Fix/Fixme' },
    },
  },
}
