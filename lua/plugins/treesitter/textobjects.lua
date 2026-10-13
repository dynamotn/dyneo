return {
  {
    -- Text objects and moves by treesitter node. `move.keys` is not an
    -- option of the plugin: `config` maps those keys in every buffer whose
    -- language has a `textobjects` query.
    'nvim-treesitter/nvim-treesitter-textobjects',
    -- `main` is the rewrite for nvim-treesitter `main`; the lockfile pins the
    -- commit on both channels
    branch = 'main',
    event = 'VeryLazy',
    keys = {
      {
        '<leader>c>',
        function()
          require('nvim-treesitter-textobjects.swap').swap_next(
            '@parameter.inner'
          )
        end,
        desc = 'Swap Next Parameter',
      },
      {
        '<leader>c<',
        function()
          require('nvim-treesitter-textobjects.swap').swap_previous(
            '@parameter.inner'
          )
        end,
        desc = 'Swap Prev Parameter',
      },
    },
    opts = {
      move = {
        enable = true,
        set_jumps = true, -- whether to set jumps in the jumplist
        keys = {
          goto_next_start = {
            [']f'] = '@function.outer',
            [']c'] = '@class.outer',
            [']a'] = '@parameter.inner',
          },
          goto_next_end = {
            [']F'] = '@function.outer',
            [']C'] = '@class.outer',
            [']A'] = '@parameter.inner',
          },
          goto_previous_start = {
            ['[f'] = '@function.outer',
            ['[c'] = '@class.outer',
            ['[a'] = '@parameter.inner',
          },
          goto_previous_end = {
            ['[F'] = '@function.outer',
            ['[C'] = '@class.outer',
            ['[A'] = '@parameter.inner',
          },
        },
      },
    },
    config = function(_, opts)
      local TS = require('nvim-treesitter-textobjects')
      if not TS.setup then
        require('util.plugin').error(
          'Please use `:Lazy` and update `nvim-treesitter`'
        )
        return
      end
      TS.setup(opts)

      local function attach(buf)
        local ft = vim.bo[buf].filetype
        if
          not (
            vim.tbl_get(opts, 'move', 'enable')
            and require('util.treesitter').have(ft, 'textobjects')
          )
        then
          return
        end
        ---@type table<string, table<string, string>>
        local moves = vim.tbl_get(opts, 'move', 'keys') or {}

        for method, keymaps in pairs(moves) do
          for key, query in pairs(keymaps) do
            -- `]f` is "Next Function Start", `[C` "Prev Class End"
            local queries = type(query) == 'table' and query or { query }
            local parts = {}
            for _, q in ipairs(queries) do
              local part = q:gsub('@', ''):gsub('%..*', '')
              part = part:sub(1, 1):upper() .. part:sub(2)
              table.insert(parts, part)
            end
            local desc = table.concat(parts, ' or ')
            desc = (key:sub(1, 1) == '[' and 'Prev ' or 'Next ') .. desc
            desc = desc
              .. (key:sub(2, 2) == key:sub(2, 2):upper() and ' End' or ' Start')
            vim.keymap.set({ 'n', 'x', 'o' }, key, function()
              -- `]c`/`[c` keep moving between changes in a diff
              if vim.wo.diff and key:find('[cC]') then
                return vim.cmd('normal! ' .. key)
              end
              require('nvim-treesitter-textobjects.move')[method](
                query,
                'textobjects'
              )
            end, {
              buffer = buf,
              desc = desc,
              silent = true,
            })
          end
        end
      end

      vim.api.nvim_create_autocmd('FileType', {
        group = vim.api.nvim_create_augroup(
          'dyneo_treesitter_textobjects',
          { clear = true }
        ),
        callback = function(ev) attach(ev.buf) end,
      })
      vim.tbl_map(attach, vim.api.nvim_list_bufs())
    end,
  },
  {
    -- Close and rename HTML and JSX tags in pairs
    'windwp/nvim-ts-autotag',
    -- The filetypes it has a tag config or an alias for
    ft = {
      'astro',
      'blade',
      'dot',
      'elixir',
      'eruby',
      'glimmer',
      'handlebars',
      'hbs',
      'heex',
      'html',
      'htmlangular',
      'htmldjango',
      'javascript',
      'javascript.glimmer',
      'javascript.jsx',
      'javascriptreact',
      'liquid',
      'markdown',
      'php',
      'rescript',
      'rust',
      'svelte',
      'templ',
      'twig',
      'typescript',
      'typescript.glimmer',
      'typescript.tsx',
      'typescriptreact',
      'vento',
      'vue',
      'xml',
    },
    opts = {},
  },
}
