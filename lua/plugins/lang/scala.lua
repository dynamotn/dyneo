local language = require('config.languages').scala

-- A Scala source or a build definition starts metals
local filetypes = vim.list_extend(vim.deepcopy(language.filetypes), { 'sbt' })

return vim.list_contains(DyNeo.enabled_languages, 'scala')
    and {
      {
        -- metals, driven by its own plugin rather than by lspconfig
        'scalameta/nvim-metals',
        ft = filetypes,
        dependencies = { 'nvim-lua/plenary.nvim' },
        keys = {
          {
            '<localleader>mc',
            function() require('metals').compile_cascade() end,
            ft = language.filetypes,
            desc = 'Metals compile cascade',
          },
          {
            '<localleader>mh',
            function() require('metals').hover_worksheet() end,
            ft = language.filetypes,
            desc = 'Metals hover worksheet',
          },
        },
        opts = function()
          local metals_config = require('metals').bare_config()
          metals_config.init_options.statusBarProvider = 'off'
          metals_config.settings = {
            verboseCompilation = true,
            showImplicitArguments = true,
            showImplicitConversionsAndClasses = true,
            showInferredType = true,
            superMethodLensesEnabled = true,
            testUserInterface = 'Test Explorer',
          }
          metals_config.on_attach = function(_, _) require('metals').setup_dap() end
          return metals_config
        end,
        config = function(self, metals_config)
          vim.api.nvim_create_autocmd('FileType', {
            group = vim.api.nvim_create_augroup('dy_metals', { clear = true }),
            -- Once it runs, metals also takes the Java sources of a Scala
            -- build; Java alone never loads it
            pattern = vim.list_extend(vim.deepcopy(self.ft), { 'java' }),
            callback = function(event)
              -- Java only in a Scala build: next to jdtls in a plain Maven or
              -- Gradle project it would be a second JVM server
              if
                vim.bo[event.buf].filetype == 'java'
                and not vim.fs.root(event.buf, {
                  'build.sbt',
                  'build.sc',
                  'build.mill',
                  '.scala-build',
                })
              then
                return
              end
              require('metals').initialize_or_attach(metals_config)
            end,
          })
        end,
      },
      {
        -- `nvim-metals` attaches the server itself, so keep lspconfig from
        -- starting a second one; the entry in `config.languages` is what
        -- documents it.
        'neovim/nvim-lspconfig',
        opts = {
          setup = {
            metals = function() return true end,
          },
        },
      },
      {
        -- Debug through metals rather than a standalone adapter
        'mfussenegger/nvim-dap',
        optional = true,
        opts = function()
          require('dap').configurations.scala = {
            {
              type = 'scala',
              request = 'launch',
              name = 'RunOrTest',
              metals = { runType = 'runOrTestFile' },
            },
            {
              type = 'scala',
              request = 'launch',
              name = 'Test Target',
              metals = { runType = 'testTarget' },
            },
          }
        end,
      },
    }
  or {}
