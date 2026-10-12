local language = require('config.languages').python

return vim.list_contains(DyNeo.enabled_languages, 'python')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            pyright = {},
            ruff = {},
            harper_ls = {},
          },
        },
      },
      {
        -- Debug adapters & configurations
        'mfussenegger/nvim-dap',
        dependencies = {
          'mfussenegger/nvim-dap-python',
          -- Not under `<leader>dP`, which is Pause and would wait for these
          keys = {
            {
              '<leader>dm',
              function() require('dap-python').test_method() end,
              ft = language.filetypes,
              desc = 'Debug Method',
            },
            {
              '<leader>dM',
              function() require('dap-python').test_class() end,
              ft = language.filetypes,
              desc = 'Debug Class',
            },
          },
          -- `debugpy-adapter` is looked up on `$PATH` as a session starts, so
          -- this holds before Mason has installed it too
          config = function() require('dap-python').setup('debugpy-adapter') end,
        },
      },
      {
        -- The adapter is nvim-dap-python's, which finds the project's own
        -- interpreter; mason-nvim-dap's would replace it with one that runs
        -- under debugpy's venv, and list its configurations a second time
        'jay-babu/mason-nvim-dap.nvim',
        optional = true,
        opts = { handlers = { python = function() end } },
      },
      {
        -- REPL: the line, the selection or the `# %%` cell sent to IPython
        'Vigemus/iron.nvim',
        cmd = { 'IronRepl', 'IronRestart', 'IronFocus', 'IronHide' },
        -- stylua: ignore
        keys = {
          { '<localleader>r', '<cmd>IronRepl<cr>', ft = language.filetypes, desc = 'Toggle REPL' },
          { '<localleader>s', function() require('iron.core').send_line() end, ft = language.filetypes, desc = 'Send Line to REPL' },
          { '<localleader>s', function() require('iron.core').visual_send() end, mode = 'x', ft = language.filetypes, desc = 'Send Selection to REPL' },
          { '<localleader>c', function() require('iron.core').send_code_block(true) end, ft = language.filetypes, desc = 'Send Cell to REPL and Move' },
          { '<localleader>f', function() require('iron.core').send_file() end, ft = language.filetypes, desc = 'Send File to REPL' },
          { '<localleader>i', function() require('iron.core').send(nil, string.char(3)) end, ft = language.filetypes, desc = 'Interrupt REPL' },
          { '<localleader>q', function() require('iron.core').close_repl() end, ft = language.filetypes, desc = 'Close REPL' },
        },
        opts = function()
          return {
            config = {
              scratch_repl = true,
              repl_definition = {
                python = {
                  -- IPython when the environment has it; read from `$PATH`
                  -- as the REPL starts, so an activated venv is the one used
                  command = function()
                    return vim.fn.executable('ipython') == 1
                        and { 'ipython', '--no-autoindent' }
                      or { 'python3' }
                  end,
                  format = require('iron.fts.common').bracketed_paste_python,
                  block_dividers = { '# %%', '#%%' },
                  -- Python 3.13's REPL mangles pasted blocks
                  env = { PYTHON_BASIC_REPL = '1' },
                },
              },
              repl_open_cmd = require('iron.view').split.vertical.botright(0.4),
            },
            highlight = { italic = true },
            ignore_blank_lines = true,
          }
        end,
        config = function(_, opts) require('iron.core').setup(opts) end,
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'nvim-neotest/neotest-python',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-python'] = {
              dap = { justMyCode = false },
              runner = 'pytest',
            },
          },
        },
      },
    }
  or {}
