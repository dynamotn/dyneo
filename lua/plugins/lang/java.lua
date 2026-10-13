local language = require('config.languages').java

-- Utility function to extend or override a config table, similar to the way
-- that Plugin.opts works.
---@param config table
---@param custom function | table | nil
local function extend_or_override(config, custom, ...)
  if type(custom) == 'function' then
    config = custom(config, ...) or config
  elseif custom then
    config = vim.tbl_deep_extend('force', config, custom) --[[@as table]]
  end
  return config
end

return vim.list_contains(DyNeo.enabled_languages, 'java')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            jdtls = {},
            harper_ls = {},
          },
          setup = {
            -- nvim-jdtls starts its own client
            jdtls = function() return true end,
          },
        },
      },
      {
        -- LSP support from Eclipse
        'mfussenegger/nvim-jdtls',
        ft = language.filetypes,
        opts = function()
          -- Looked up on `$PATH` when the server starts: Mason may still be
          -- installing it when the first Java file loads this
          local cmd = { 'jdtls' }
          if require('util.plugin').has('mason.nvim') then
            table.insert(
              cmd,
              string.format(
                '--jvm-arg=-javaagent:%s',
                vim.fn.expand('$MASON/share/jdtls/lombok.jar')
              )
            )
          end
          return {
            root_dir = function(path)
              return vim.fs.root(path, vim.lsp.config.jdtls.root_markers)
            end,

            -- How to find the project name for a given root dir.
            project_name = function(root_dir)
              return root_dir and vim.fs.basename(root_dir)
            end,

            -- Where are the config and workspace dirs for a project?
            jdtls_config_dir = function(project_name)
              return vim.fn.stdpath('cache')
                .. '/jdtls/'
                .. project_name
                .. '/config'
            end,
            jdtls_workspace_dir = function(project_name)
              return vim.fn.stdpath('cache')
                .. '/jdtls/'
                .. project_name
                .. '/workspace'
            end,

            -- How to run jdtls. This can be overridden to a full java command-line
            -- if the Python wrapper script doesn't suffice.
            cmd = cmd,
            full_cmd = function(opts)
              local fname = vim.api.nvim_buf_get_name(0)
              local root_dir = opts.root_dir(fname)
              local project_name = opts.project_name(root_dir)
              ---@diagnostic disable-next-line: redefined-local
              local cmd = vim.deepcopy(opts.cmd)
              if project_name then
                vim.list_extend(cmd, {
                  '-configuration',
                  opts.jdtls_config_dir(project_name),
                  '-data',
                  opts.jdtls_workspace_dir(project_name),
                })
              end
              return cmd
            end,

            -- These depend on nvim-dap, but can additionally be disabled by setting false here.
            dap = { hotcodereplace = 'auto', config_overrides = {} },
            -- Can set this to false to disable main class scan, which is a performance killer for large project
            dap_main = {},
            test = true,
            settings = {
              java = {
                inlayHints = {
                  parameterNames = {
                    enabled = 'all',
                  },
                },
              },
            },
          }
        end,
        config = function(_, opts)
          -- Find the extra bundles that should be passed on the jdtls command-line
          -- if nvim-dap is enabled with java debug/test.
          local bundles = {} ---@type string[]
          if require('util.plugin').has('mason.nvim') then
            local mason_registry = require('mason-registry')
            if
              opts.dap
              and require('util.plugin').has('nvim-dap')
              and mason_registry.is_installed('java-debug-adapter')
            then
              bundles = vim.fn.glob(
                '$MASON/share/java-debug-adapter/com.microsoft.java.debug.plugin-*jar',
                false,
                true
              )
              -- java-test also depends on java-debug-adapter.
              if opts.test and mason_registry.is_installed('java-test') then
                vim.list_extend(
                  bundles,
                  vim.fn.glob('$MASON/share/java-test/*.jar', false, true)
                )
              end
            end
          end
          local function attach_jdtls()
            local fname = vim.api.nvim_buf_get_name(0)

            -- Configuration can be augmented and overridden by opts.jdtls
            local config = extend_or_override({
              cmd = opts.full_cmd(opts),
              root_dir = opts.root_dir(fname),
              init_options = {
                bundles = bundles,
              },
              settings = opts.settings,
              -- enable CMP capabilities
              capabilities = require('util.plugin').has('blink.cmp')
                  and require('blink.cmp').get_lsp_capabilities()
                or nil,
            }, opts.jdtls)

            -- Existing server will be reused if the root_dir matches.
            require('jdtls').start_or_attach(config)
            -- not need to require("jdtls.setup").add_commands(), start automatically adds commands
          end

          -- Attach the jdtls for each java buffer. HOWEVER, this plugin loads
          -- depending on filetype, so this autocmd doesn't run for the first file.
          -- For that, we call directly below.
          -- One group for both, cleared each time this runs, so `:Lazy reload`
          -- does not attach jdtls twice
          local group =
            vim.api.nvim_create_augroup('dyneo_jdtls', { clear = true })
          vim.api.nvim_create_autocmd('FileType', {
            group = group,
            pattern = language.filetypes,
            callback = attach_jdtls,
          })

          -- Setup keymap and dap after the lsp is fully attached.
          -- https://github.com/mfussenegger/nvim-jdtls#nvim-dap-configuration
          -- https://neovim.io/doc/user/lsp.html#LspAttach
          vim.api.nvim_create_autocmd('LspAttach', {
            group = group,
            callback = function(args)
              local client = vim.lsp.get_client_by_id(args.data.client_id)
              if client and client.name == 'jdtls' then
                local wk = require('which-key')
                wk.add({
                  {
                    mode = 'n',
                    buffer = args.buf,
                    { '<leader>cx', group = 'extract' },
                    {
                      '<leader>cxv',
                      require('jdtls').extract_variable_all,
                      desc = 'Extract Variable',
                    },
                    {
                      '<leader>cxc',
                      require('jdtls').extract_constant,
                      desc = 'Extract Constant',
                    },
                    {
                      '<leader>cgs',
                      require('jdtls').super_implementation,
                      desc = 'Goto Super',
                    },
                    {
                      '<leader>cgS',
                      require('jdtls.tests').goto_subjects,
                      desc = 'Goto Subjects',
                    },
                    {
                      '<leader>co',
                      require('jdtls').organize_imports,
                      desc = 'Organize Imports',
                    },
                  },
                })
                wk.add({
                  {
                    mode = 'x',
                    buffer = args.buf,
                    { '<leader>cx', group = 'extract' },
                    {
                      '<leader>cxm',
                      [[<ESC><CMD>lua require('jdtls').extract_method(true)<CR>]],
                      desc = 'Extract Method',
                    },
                    {
                      '<leader>cxv',
                      [[<ESC><CMD>lua require('jdtls').extract_variable_all(true)<CR>]],
                      desc = 'Extract Variable',
                    },
                    {
                      '<leader>cxc',
                      [[<ESC><CMD>lua require('jdtls').extract_constant(true)<CR>]],
                      desc = 'Extract Constant',
                    },
                  },
                })

                if require('util.plugin').has('mason.nvim') then
                  local mason_registry = require('mason-registry')
                  if
                    opts.dap
                    and require('util.plugin').has('nvim-dap')
                    and mason_registry.is_installed('java-debug-adapter')
                  then
                    -- custom init for Java debugger
                    require('jdtls').setup_dap(opts.dap)
                    if opts.dap_main then
                      require('jdtls.dap').setup_dap_main_class_configs(
                        opts.dap_main
                      )
                    end

                    -- Java Test require Java debugger to work
                    if
                      opts.test and mason_registry.is_installed('java-test')
                    then
                      -- The jdtls runner, beside neotest-java: on the local
                      -- leader, so `<leader>t` stays neotest's
                      wk.add({
                        {
                          mode = 'n',
                          buffer = args.buf,
                          {
                            '<localleader>t',
                            function()
                              require('jdtls.dap').test_class({
                                config_overrides = type(opts.test) ~= 'boolean'
                                    and opts.test.config_overrides
                                  or nil,
                              })
                            end,
                            desc = 'Run All Test',
                          },
                          {
                            '<localleader>r',
                            function()
                              require('jdtls.dap').test_nearest_method({
                                config_overrides = type(opts.test) ~= 'boolean'
                                    and opts.test.config_overrides
                                  or nil,
                              })
                            end,
                            desc = 'Run Nearest Test',
                          },
                          {
                            '<localleader>T',
                            require('jdtls.dap').pick_test,
                            desc = 'Run Test',
                          },
                        },
                      })
                    end
                  end
                end

                -- User can set additional keymaps in opts.on_attach
                if opts.on_attach then opts.on_attach(args) end
              end
            end,
          })

          -- Avoid race condition by calling attach the first time, since the autocmd won't fire.
          attach_jdtls()
        end,
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          'rcasia/neotest-java',
          ft = language.filetypes,
        },
        opts = {
          adapters = {
            ['neotest-java'] = {},
          },
        },
      },
    }
  or {}
