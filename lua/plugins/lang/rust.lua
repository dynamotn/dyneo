local language = require('config.languages').rust

return vim.list_contains(DyNeo.enabled_languages, 'rust')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          setup = {
            -- rustaceanvim starts its own client
            rust_analyzer = function() return true end,
          },
        },
      },
      {
        -- Powerful toolbox
        'mrcjkb/rustaceanvim',
        ft = language.filetypes,
        opts = {
          server = {
            on_attach = function(_, bufnr)
              local function map(lhs, cmd, desc)
                vim.keymap.set(
                  'n',
                  lhs,
                  function() vim.cmd.RustLsp(cmd) end,
                  { desc = desc, buffer = bufnr }
                )
              end
              -- Not `<leader>cR`, which renames the file
              map('<localleader>a', 'codeAction', 'Code Action')
              -- Not `<leader>dr`, which is the dap REPL
              map('<leader>dR', 'debuggables', 'Rust Debuggables')
              map('<localleader>e', 'explainError', 'Explain Error')
              map('<localleader>m', 'expandMacro', 'Expand Macro')
              map('<localleader>r', 'runnables', 'Runnables')
              map('<localleader>t', 'testables', 'Testables')
              map('<localleader>c', 'openCargo', 'Open Cargo.toml')
            end,
            default_settings = {
              -- rust-analyzer language server configuration
              ['rust-analyzer'] = {
                cargo = {
                  allFeatures = true,
                  loadOutDirsFromCheck = true,
                  buildScripts = {
                    enable = true,
                  },
                },
                -- Run the check on save; rustaceanvim makes it `clippy` when
                -- `cargo-clippy` is on `$PATH`
                checkOnSave = true,
                -- rust-analyzer's own diagnostics, on top of the check's
                diagnostics = {
                  enable = true,
                },
                procMacro = {
                  enable = true,
                },
                files = {
                  exclude = {
                    '.direnv',
                    '.git',
                    '.github',
                    '.gitlab',
                    'bin',
                    'node_modules',
                    'target',
                    'venv',
                    '.venv',
                  },
                  -- Avoid Roots Scanned hanging, see https://github.com/rust-lang/rust-analyzer/issues/12613#issuecomment-2096386344
                  watcher = 'client',
                },
              },
            },
          },
        },
        -- No `dap.adapter`: rustaceanvim finds Mason's codelldb and its
        -- liblldb itself as a session starts, where a path read here was
        -- empty for good whenever codelldb was installed after startup
        config = function(_, opts)
          vim.g.rustaceanvim =
            vim.tbl_deep_extend('keep', vim.g.rustaceanvim or {}, opts or {})
          if vim.fn.executable('rust-analyzer') == 0 then
            require('util.plugin').error(
              '**rust-analyzer** not found in PATH, please install it.\nhttps://rust-analyzer.github.io/',
              { title = require('util.notify').title('Rust') }
            )
          end
        end,
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        -- Requiring the adapter loads rustaceanvim, whose `config` complains
        -- about rust-analyzer: only where Rust can be built at all
        opts = function(_, opts)
          opts.adapters = opts.adapters or {}
          opts.adapters['rustaceanvim.neotest'] = vim.fn.executable('cargo')
                == 1
              and {}
            or false
        end,
      },
    }
  or {}
