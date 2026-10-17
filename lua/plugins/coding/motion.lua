return {
  {
    -- Pin files and jump between them
    'ThePrimeagen/harpoon',
    -- `harpoon2` is the current line; `master` is the old plugin. The
    -- lockfile pins the commit on both channels
    branch = 'harpoon2',
    opts = {
      settings = {
        save_on_toggle = true,
      },
    },
    keys = function()
      local keys = {
        {
          '<leader>H',
          function() require('harpoon'):list():add() end,
          desc = 'Harpoon File',
        },
        {
          '<leader>h',
          function()
            local harpoon = require('harpoon')
            harpoon.ui:toggle_quick_menu(harpoon:list())
          end,
          desc = 'Harpoon Quick Menu',
        },
      }

      for i = 1, 9 do
        table.insert(keys, {
          '<leader>' .. i,
          function() require('harpoon'):list():select(i) end,
          desc = 'Harpoon to File ' .. i,
        })
      end
      return keys
    end,
  },
  {
    -- Add, delete, replace, find and highlight surroundings, under `gs`
    'nvim-mini/mini.surround',
    keys = function(_, keys)
      -- Lazy-load on whichever keys the options end up mapping
      local opts = require('util.plugin').opts('mini.surround')
      local mappings = {
        { opts.mappings.add, desc = 'Add Surrounding', mode = { 'n', 'x' } },
        { opts.mappings.delete, desc = 'Delete Surrounding' },
        { opts.mappings.find, desc = 'Find Right Surrounding' },
        { opts.mappings.find_left, desc = 'Find Left Surrounding' },
        { opts.mappings.highlight, desc = 'Highlight Surrounding' },
        { opts.mappings.replace, desc = 'Replace Surrounding' },
        {
          opts.mappings.update_n_lines,
          desc = 'Update `MiniSurround.config.n_lines`',
        },
      }
      mappings = vim.tbl_filter(
        function(m) return m[1] and #m[1] > 0 end,
        mappings
      )
      return vim.list_extend(mappings, keys)
    end,
    opts = {
      mappings = {
        add = 'gsa', -- Add surrounding in Normal and Visual modes
        delete = 'gsd', -- Delete surrounding
        find = 'gsf', -- Find surrounding (to the right)
        find_left = 'gsF', -- Find surrounding (to the left)
        highlight = 'gsh', -- Highlight surrounding
        replace = 'gsr', -- Replace surrounding
        update_n_lines = 'gsn', -- Update `n_lines`
      },
    },
  },
  {
    -- More `a`/`i` text objects: arguments, calls, blocks, functions,
    -- classes, tags, digits, subwords and the whole buffer; `an`/`al` and
    -- the like reach the next or last one
    'nvim-mini/mini.ai',
    event = 'VeryLazy',
    opts = function()
      local ai = require('mini.ai')
      return {
        n_lines = 500,
        custom_textobjects = {
          o = ai.gen_spec.treesitter({ -- code block
            a = { '@block.outer', '@conditional.outer', '@loop.outer' },
            i = { '@block.inner', '@conditional.inner', '@loop.inner' },
          }),
          f = ai.gen_spec.treesitter({
            a = '@function.outer',
            i = '@function.inner',
          }), -- function
          c = ai.gen_spec.treesitter({ a = '@class.outer', i = '@class.inner' }), -- class
          t = { '<([%p%w]-)%f[^<%w][^<>]->.-</%1>', '^<.->().*()</[^/]->$' }, -- tags
          d = { '%f[%d]%d+' }, -- digits
          e = { -- Word with case
            {
              '%u[%l%d]+%f[^%l%d]',
              '%f[%S][%l%d]+%f[^%l%d]',
              '%f[%P][%l%d]+%f[^%l%d]',
              '^[%l%d]+%f[^%l%d]',
            },
            '^().*()$',
          },
          g = require('util.mini').ai_buffer, -- buffer
          u = ai.gen_spec.function_call(), -- u for "Usage"
          U = ai.gen_spec.function_call({ name_pattern = '[%w_]' }), -- without dot in function name
        },
      }
    end,
    config = function(_, opts)
      require('mini.ai').setup(opts)
      require('util.plugin').on_load('which-key.nvim', function()
        vim.schedule(function() require('util.mini').ai_whichkey(opts) end)
      end)
    end,
  },
  {
    -- Interact and manipulate marks
    'chentoast/marks.nvim',
    event = 'VeryLazy',
    opts = {
      default_mappings = true,
      -- Its own mappings redraw the signs at once; the timer only catches
      -- marks set otherwise, and its default 150 ms wakes the editor often
      refresh_interval = 250,
    },
  },
  {
    -- Match and move between keyword pairs, not only brackets
    --
    -- The built-in `matchit` already teaches `%` about `if`/`end`, but it
    -- stops there: nothing highlights the other half, and a pair whose
    -- opening is scrolled away leaves no clue where it began. Both matter
    -- here, where every language that can take `endwise` gets it.
    'andymass/vim-matchup',
    event = { 'BufReadPost', 'BufNewFile' },
    init = function()
      -- The offscreen half is normally drawn over the status line, which
      -- lualine and noice already own, so it goes in a popup instead.
      vim.g.matchup_matchparen_offscreen = { method = 'popup' }
      -- Highlight once the cursor settles. Matching a keyword pair means
      -- walking the buffer, and doing that on every single motion is what
      -- makes matchup feel slow in a large file.
      vim.g.matchup_matchparen_deferred = 1
      -- `nvim-ts-autotag` is the one renaming HTML tag pairs; matchup's own
      -- transmute would be a second writer on the same edit.
      vim.g.matchup_transmute_enabled = 0
    end,
  },
  {
    -- w/e/b/ge by subword, over insignificant punctuation
    'chrisgrieser/nvim-spider',
    -- Ex commands rather than functions, or `.` cannot repeat them
    keys = {
      {
        'w',
        "<cmd>lua require('spider').motion('w')<cr>",
        mode = { 'n', 'o', 'x' },
        desc = 'Next subword',
      },
      {
        'e',
        "<cmd>lua require('spider').motion('e')<cr>",
        mode = { 'n', 'o', 'x' },
        desc = 'End of subword',
      },
      {
        'b',
        "<cmd>lua require('spider').motion('b')<cr>",
        mode = { 'n', 'o', 'x' },
        desc = 'Previous subword',
      },
      {
        'ge',
        "<cmd>lua require('spider').motion('ge')<cr>",
        mode = { 'n', 'o', 'x' },
        desc = 'End of previous subword',
      },
      -- Its `cw` changes up to the next word, as `dw` deletes; keep Vim's
      -- change to the end of the word instead.
      {
        'cw',
        "c<cmd>lua require('spider').motion('e')<cr>",
        desc = 'Change to end of subword',
      },
    },
  },
}
