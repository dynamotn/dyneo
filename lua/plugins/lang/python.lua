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
        -- Virtual environments: picked once per project from uv, poetry,
        -- conda, pyenv and the rest, then put back as a file of the project
        -- opens. It sets `$VIRTUAL_ENV` and `$PATH` and restarts the Python
        -- servers in it, so pyright, the debugger, the REPL and the tasks all
        -- follow it.
        'linux-cultist/venv-selector.nvim',
        ft = language.filetypes,
        cmd = 'VenvSelect',
        keys = {
          {
            '<localleader>v',
            '<cmd>VenvSelect<cr>',
            ft = language.filetypes,
            desc = 'Select Virtualenv',
          },
        },
        opts = { options = { picker = 'snacks' } },
        config = function(_, opts)
          require('venv-selector').setup(opts)
          -- A script declaring its dependencies (PEP 723) is synced with
          -- `uv sync --script` as it opens and after each write: that
          -- installs whatever a file from someone else's repository asks
          -- for, and may build it from source. It runs once agreed to.
          local uv2 = require('venv-selector.uv2')
          local run = uv2.run_uv_flow_if_needed
          uv2.run_uv_flow_if_needed = function(bufnr)
            if not bufnr or bufnr == 0 then
              bufnr = vim.api.nvim_get_current_buf()
            end
            if not vim.api.nvim_buf_is_valid(bufnr) then return end
            if uv2.is_uv_buffer(bufnr) then
              local verdict = vim.b[bufnr].dy_uv_allowed
              if verdict == nil then
                -- Pinned before asking: the prompt keeps handling events
                vim.b[bufnr].dy_uv_allowed = false
                verdict = vim.fn.confirm(
                  ('Install the dependencies %s declares with `uv sync --script`?'):format(
                    vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ':~:.')
                  ),
                  '&Install\n&Cancel',
                  2
                ) == 1
                vim.b[bufnr].dy_uv_allowed = verdict
              end
              if not verdict then return end
            end
            return run(bufnr)
          end
        end,
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
          -- The command the REPL was started with: the paste format follows
          -- it, not whichever venv is active by the time a line is sent
          local started
          local paste = require('iron.fts.common').bracketed_paste_python
          return {
            config = {
              scratch_repl = true,
              repl_definition = {
                python = {
                  -- IPython when the environment has it; read from `$PATH`
                  -- as the REPL starts, so an activated venv is the one used
                  command = function()
                    started = vim.fn.executable('ipython') == 1
                        and { 'ipython', '--no-autoindent' }
                      or { 'python3' }
                    return started
                  end,
                  format = function(lines, extras)
                    if started then
                      extras = vim.tbl_extend('force', extras, {
                        command = started,
                      })
                    end
                    return paste(lines, extras)
                  end,
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
