local languages = require('config.languages')
local language = languages.typescript
--- Every filetype the JavaScript debugger serves: plain, JSX and TypeScript
---@type string[]
local js_filetypes = vim
  .iter({
    languages.javascript.filetypes,
    languages.tsx.filetypes,
    languages.typescript.filetypes,
  })
  :flatten()
  :totable()
local condition = vim.list_contains(DyNeo.enabled_languages, 'typescript')
  or vim.list_contains(DyNeo.enabled_languages, 'javascript')
  or vim.list_contains(DyNeo.enabled_languages, 'tsx')
  or vim.list_contains(DyNeo.enabled_languages, 'angular')
  or vim.list_contains(DyNeo.enabled_languages, 'vue')
  or vim.list_contains(DyNeo.enabled_languages, 'svelte')
  or vim.list_contains(DyNeo.enabled_languages, 'astro')
return condition
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            vtsls = {
              settings = {
                complete_function_calls = true,
                vtsls = {
                  enableMoveToFileCodeAction = true,
                  autoUseWorkspaceTsdk = true,
                  experimental = {
                    maxInlayHintLength = 30,
                    completion = {
                      enableServerSideFuzzyMatch = true,
                    },
                  },
                },
                typescript = {
                  updateImportsOnFileMove = { enabled = 'always' },
                  suggest = {
                    completeFunctionCalls = true,
                  },
                  inlayHints = {
                    enumMemberValues = { enabled = true },
                    functionLikeReturnTypes = { enabled = true },
                    parameterNames = { enabled = 'literals' },
                    parameterTypes = { enabled = true },
                    propertyDeclarationTypes = { enabled = true },
                    variableTypes = { enabled = false },
                  },
                },
              },
              keys = {
                {
                  'gD',
                  function()
                    local win = vim.api.nvim_get_current_win()
                    local params =
                      vim.lsp.util.make_position_params(win, 'utf-16')
                    require('util.lsp').execute({
                      command = 'typescript.goToSourceDefinition',
                      arguments = { params.textDocument.uri, params.position },
                      open = true,
                    })
                  end,
                  desc = 'Goto Source Definition',
                },
                {
                  'gR',
                  function()
                    require('util.lsp').execute({
                      command = 'typescript.findAllFileReferences',
                      arguments = { vim.uri_from_bufnr(0) },
                      open = true,
                    })
                  end,
                  desc = 'File References',
                },
                {
                  '<leader>co',
                  require('util.lsp').action['source.organizeImports'],
                  desc = 'Organize Imports',
                },
                {
                  '<leader>cM',
                  require('util.lsp').action['source.addMissingImports.ts'],
                  desc = 'Add missing imports',
                },
                {
                  '<leader>cu',
                  require('util.lsp').action['source.removeUnused.ts'],
                  desc = 'Remove unused imports',
                },
                {
                  '<leader>cD',
                  require('util.lsp').action['source.fixAll.ts'],
                  desc = 'Fix all diagnostics',
                },
                {
                  '<leader>cV',
                  function()
                    require('util.lsp').execute({
                      command = 'typescript.selectTypeScriptVersion',
                    })
                  end,
                  desc = 'Select TS workspace version',
                },
              },
            },
            harper_ls = {},
          },
          setup = {
            vtsls = function(_, opts)
              Snacks.util.lsp.on({ name = 'vtsls' }, function(_, client)
                client.commands['_typescript.moveToFileRefactoring'] = function(
                  command,
                  _
                )
                  ---@type string, string, boolean|string|number|boolean|string|number|table<string, lsp.LSPAny>|table<string, lsp.LSPAny>[]
                  local action, uri, range = unpack(command.arguments)

                  local function move(newf)
                    client:request('workspace/executeCommand', {
                      command = command.command,
                      arguments = { action, uri, range, newf },
                    })
                  end

                  local fname = vim.uri_to_fname(uri)
                  client:request('workspace/executeCommand', {
                    command = 'typescript.tsserverRequest',
                    arguments = {
                      'getMoveToRefactoringFileSuggestions',
                      {
                        file = fname,
                        startLine = range.start.line + 1,
                        startOffset = range.start.character + 1,
                        endLine = range['end'].line + 1,
                        endOffset = range['end'].character + 1,
                      },
                    },
                  }, function(_, result)
                    ---@type string[]
                    local files = result.body.files
                    table.insert(files, 1, 'Enter new path...')
                    vim.ui.select(files, {
                      prompt = 'Select move destination:',
                      format_item = function(f)
                        return vim.fn.fnamemodify(f, ':~:.')
                      end,
                    }, function(f)
                      if f and f:find('^Enter new path') then
                        vim.ui.input({
                          prompt = 'Enter move destination:',
                          default = vim.fn.fnamemodify(fname, ':h') .. '/',
                          completion = 'file',
                        }, function(newf)
                          ---@diagnostic disable-next-line: redundant-return-value
                          return newf and move(newf)
                        end)
                      elseif f then
                        move(f)
                      end
                    end)
                  end)
                end
              end)
              -- copy typescript settings to javascript
              opts.settings.javascript = vim.tbl_deep_extend(
                'force',
                {},
                opts.settings.typescript,
                opts.settings.javascript or {}
              )
            end,
          },
        },
      },
      {
        -- Extend LSP config of vtsls by plugin for Typescript and Javascript
        'neovim/nvim-lspconfig',
        opts = function(_, opts)
          require('util.plugin').extend(
            opts.servers.vtsls,
            'filetypes',
            language.filetypes
          )
        end,
      },
      {
        -- Debug adapters & configurations
        'mfussenegger/nvim-dap',
        opts = function()
          local dap = require('dap')
          -- The targets js-debug knows; Firefox has an adapter of its own,
          -- from mason-nvim-dap
          for _, adapterType in ipairs({ 'node', 'chrome', 'msedge' }) do
            local pwaType = 'pwa-' .. adapterType

            if not dap.adapters[pwaType] then
              dap.adapters[pwaType] = {
                type = 'server',
                host = 'localhost',
                port = '${port}',
                executable = {
                  command = 'js-debug-adapter',
                  args = { '${port}' },
                },
              }
            end

            -- Define adapters without the "pwa-" prefix for VSCode compatibility
            if not dap.adapters[adapterType] then
              dap.adapters[adapterType] = function(cb, config)
                local nativeAdapter = dap.adapters[pwaType]

                config.type = pwaType

                if type(nativeAdapter) == 'function' then
                  nativeAdapter(cb, config)
                else
                  cb(nativeAdapter)
                end
              end
            end
          end

          local vscode = require('dap.ext.vscode')
          vscode.type_to_filetypes['node'] = js_filetypes
          vscode.type_to_filetypes['pwa-node'] = js_filetypes

          -- Ahead of whatever is there already rather than instead of it:
          -- mason-nvim-dap's Firefox handler may have run first, and its
          -- configurations would otherwise have been the only ones
          for _, filetype in ipairs(js_filetypes) do
            local runtimeExecutable = nil
            if filetype:find('typescript') then
              runtimeExecutable = vim.fn.executable('tsx') == 1 and 'tsx'
                or 'ts-node'
            end
            dap.configurations[filetype] = vim.list_extend({
              {
                type = 'pwa-node',
                request = 'launch',
                name = 'Launch file',
                program = '${file}',
                cwd = '${workspaceFolder}',
                sourceMaps = true,
                runtimeExecutable = runtimeExecutable,
                skipFiles = {
                  '<node_internals>/**',
                  'node_modules/**',
                },
                resolveSourceMapLocations = {
                  '${workspaceFolder}/**',
                  '!**/node_modules/**',
                },
              },
              {
                type = 'pwa-node',
                request = 'attach',
                name = 'Attach',
                processId = require('dap.utils').pick_process,
                cwd = '${workspaceFolder}',
                sourceMaps = true,
                runtimeExecutable = runtimeExecutable,
                skipFiles = {
                  '<node_internals>/**',
                  'node_modules/**',
                },
                resolveSourceMapLocations = {
                  '${workspaceFolder}/**',
                  '!**/node_modules/**',
                },
              },
            }, dap.configurations[filetype] or {})
          end

          -- A frontend runs in the browser: Vue, Svelte, Astro and Angular
          -- components get only this one, scripts get it beside the Node ones
          local browser_filetypes = vim
            .iter({
              js_filetypes,
              languages.vue.filetypes,
              languages.svelte.filetypes,
              languages.astro.filetypes,
              languages.angular.filetypes,
            })
            :flatten()
            :totable()
          vscode.type_to_filetypes['chrome'] = browser_filetypes
          vscode.type_to_filetypes['pwa-chrome'] = browser_filetypes
          for _, filetype in ipairs(browser_filetypes) do
            dap.configurations[filetype] =
              vim.list_extend(dap.configurations[filetype] or {}, {
                {
                  type = 'pwa-chrome',
                  request = 'launch',
                  name = 'Launch Chrome',
                  url = function()
                    return vim.fn.input(
                      'URL: ',
                      require('util.dap').dev_server_url()
                    )
                  end,
                  webRoot = '${workspaceFolder}',
                  sourceMaps = true,
                },
              })
          end
        end,
      },
      {
        -- Test adapter
        'nvim-neotest/neotest',
        dependencies = {
          {
            'nvim-neotest/neotest-jest',
            ft = language.filetypes,
          },
          {
            'marilari88/neotest-vitest',
            ft = language.filetypes,
          },
          {
            'thenbe/neotest-playwright',
            ft = language.filetypes,
          },
        },
        opts = {
          adapters = {
            -- The command and the config file are left to the adapter, which
            -- finds the project's own jest and the nearest `jest.config.*`
            ['neotest-jest'] = {
              env = { CI = true },
              cwd = function(_) return require('util.root').get() end,
            },
            ['neotest-vitest'] = {},
            ['neotest-playwright'] = {
              options = {
                persist_project_selection = true,
                enable_dynamic_test_discovery = true,
              },
            },
          },
        },
      },
      {
        -- Filetype icons
        'nvim-mini/mini.icons',
        opts = {
          file = {
            ['.eslintrc.js'] = { glyph = '󰱺 ', hl = 'MiniIconsYellow' },
            ['.node-version'] = { glyph = ' ', hl = 'MiniIconsGreen' },
            ['.prettierrc'] = { glyph = '', hl = 'MiniIconsPurple' },
            ['.yarnrc.yml'] = { glyph = ' ', hl = 'MiniIconsBlue' },
            ['eslint.config.js'] = { glyph = '󰱺 ', hl = 'MiniIconsYellow' },
            ['package.json'] = { glyph = ' ', hl = 'MiniIconsGreen' },
            ['tsconfig.json'] = { glyph = ' ', hl = 'MiniIconsAzure' },
            ['tsconfig.build.json'] = { glyph = ' ', hl = 'MiniIconsAzure' },
            ['yarn.lock'] = { glyph = ' ', hl = 'MiniIconsBlue' },
          },
        },
      },
    }
  or {}
