local languages = require('config.languages')
local not_supported_filetypes = {}
for _, language in pairs(languages) do
  if type(language.test) ~= 'table' then
    vim.list_extend(not_supported_filetypes, language.filetypes)
  else
    local vim_test_supported = false
    for _, adapter in ipairs(language.test) do
      if adapter == 'vim-test' then vim_test_supported = true end
    end
    if not vim_test_supported then
      vim.list_extend(not_supported_filetypes, language.filetypes)
    end
  end
end

--- Turn `adapters` into adapter instances: a list item is an adapter or the
--- module of one, a named entry is the module of an adapter set up with its
--- value, or left out when that is false
---@param adapters table
---@return table
local function load_adapters(adapters)
  local ret = {}
  for name, config in pairs(adapters) do
    if type(name) == 'number' then
      if type(config) == 'string' then config = require(config) end
      ret[#ret + 1] = config
    elseif config ~= false then
      local adapter = require(name)
      if type(config) == 'table' and not vim.tbl_isempty(config) then
        local meta = getmetatable(adapter)
        if adapter.setup then
          adapter.setup(config)
        elseif adapter.adapter then
          adapter.adapter(config)
          adapter = adapter.adapter
        elseif meta and meta.__call then
          adapter = adapter(config)
        else
          error('Adapter ' .. name .. ' does not support setup')
        end
      end
      ret[#ret + 1] = adapter
    end
  end
  return ret
end

--- Consumer refreshing trouble after a run, and closing it when every test
--- passed
---@type neotest.Consumer
local function trouble_consumer(client)
  client.listeners.results = function(adapter_id, results, partial)
    if partial then return end
    local tree = assert(client:get_position(nil, { adapter = adapter_id }))

    local failed = 0
    for pos_id, result in pairs(results) do
      if result.status == 'failed' and tree:get_key(pos_id) then
        failed = failed + 1
      end
    end
    vim.schedule(function()
      local trouble = require('trouble')
      if trouble.is_open() then
        trouble.refresh()
        if failed == 0 then trouble.close() end
      end
    end)
    return {}
  end
end

return {
  {
    -- Test integration
    'nvim-neotest/neotest',
    -- stylua: ignore
    keys = {
      { '<leader>t', '', desc = '+test' },
      { '<leader>ta', function() require('neotest').run.attach() end, desc = 'Attach to Test (Neotest)' },
      { '<leader>tt', function() require('neotest').run.run(vim.fn.expand('%')) end, desc = 'Run File (Neotest)' },
      { '<leader>tT', function() require('neotest').run.run(vim.uv.cwd()) end, desc = 'Run All Test Files (Neotest)' },
      { '<leader>tr', function() require('neotest').run.run() end, desc = 'Run Nearest (Neotest)' },
      { '<leader>tl', function() require('neotest').run.run_last() end, desc = 'Run Last (Neotest)' },
      { '<leader>ts', function() require('neotest').summary.toggle() end, desc = 'Toggle Summary (Neotest)' },
      { '<leader>to', function() require('neotest').output.open({ enter = true, auto_close = true }) end, desc = 'Show Output (Neotest)' },
      { '<leader>tO', function() require('neotest').output_panel.toggle() end, desc = 'Toggle Output Panel (Neotest)' },
      { '<leader>tS', function() require('neotest').run.stop() end, desc = 'Stop (Neotest)' },
      { '<leader>tw', function() require('neotest').watch.toggle(vim.fn.expand('%')) end, desc = 'Toggle Watch (Neotest)' },
      { ']n', function() require('neotest').jump.next({ status = 'failed' }) end, desc = 'Next Failed Test' },
      { '[n', function() require('neotest').jump.prev({ status = 'failed' }) end, desc = 'Prev Failed Test' },
    },
    config = function(_, opts)
      local neotest_ns = vim.api.nvim_create_namespace('neotest')
      -- tiny-inline-diagnostic draws every namespace already; virtual text of
      -- its own would show each failure twice
      local tiny = require('util.plugin').has('tiny-inline-diagnostic.nvim')
      vim.diagnostic.config({
        virtual_text = not tiny and {
          format = function(diagnostic)
            -- Keep the message on one line
            local message = diagnostic.message
              :gsub('\n', ' ')
              :gsub('\t', ' ')
              :gsub('%s+', ' ')
              :gsub('^%s+', '')
            return message
          end,
        },
      }, neotest_ns)

      if require('util.plugin').has('trouble.nvim') then
        opts.consumers = opts.consumers or {}
        opts.consumers.trouble = trouble_consumer
      end
      if opts.adapters then opts.adapters = load_adapters(opts.adapters) end

      require('neotest').setup(opts)
    end,
    dependencies = {
      'nvim-neotest/nvim-nio',
      {
        -- Test runner compatibility that support vim-test
        'nvim-neotest/neotest-vim-test',
        dependencies = {
          'vim-test/vim-test',
          keys = {
            {
              '<leader>tf',
              '<cmd>TestFile<cr>',
              desc = 'Run File (Vimtest)',
            },
          },
          config = function(_, _)
            -- Run in a floating zellij pane. The command goes to the shell
            -- as one argument rather than through `:!`, which would expand
            -- `%`, `#` and `!` in it and hold the editor until zellij returns.
            if DyNeo.test_strategy == 'zellij' then
              vim.g['test#custom_strategies'] = {
                zellij = function(cmd)
                  local argv = {
                    'zellij',
                    'run',
                    '--floating',
                    '--cwd',
                    vim.fn.getcwd(),
                    '--',
                    vim.o.shell,
                  }
                  vim.list_extend(
                    argv,
                    vim.split(vim.o.shellcmdflag, ' ', {
                      trimempty = true,
                    })
                  )
                  table.insert(argv, cmd)
                  vim.fn.jobstart(argv, { detach = true })
                end,
              }
            end
            vim.g['test#strategy'] = DyNeo.test_strategy
          end,
        },
      },
    },
    opts = {
      -- A list of adapters, of adapter modules, or a table of adapter
      -- modules to their config, see `load_adapters`
      adapters = {
        ['neotest-vim-test'] = {
          ignore_filetypes = not_supported_filetypes,
        },
      },
      status = { virtual_text = true },
      output = { open_on_run = true },
      quickfix = {
        open = function()
          if require('util.plugin').has('trouble.nvim') then
            require('trouble').open({ mode = 'quickfix', focus = false })
          else
            vim.cmd('copen')
          end
        end,
      },
    },
  },
  {
    'mfussenegger/nvim-dap',
    optional = true,
    -- stylua: ignore
    keys = {
      { '<leader>td', function() require('neotest').run.run({ strategy = 'dap' }) end, desc = 'Debug Nearest' },
    },
  },
  {
    -- Coverage from LCOV, Cobertura, Go, tarpaulin and LLVM reports
    'mr-u0b0dy/crazy-coverage.nvim',
    -- Upstream ships doc/ as Markdown only, so lazy.nvim's helptags step dies
    -- with "E151: No match: .../doc/**/*.txt". Lay down a stub vimdoc that
    -- points at the Markdown, so the directory has something to index.
    build = function(plugin)
      local doc = plugin.dir .. '/doc'
      local help = doc .. '/crazy-coverage.txt'
      if not vim.uv.fs_stat(help) then
        vim.fn.writefile({
          '*crazy-coverage.txt*	Coverage from LCOV, Cobertura, Go and LLVM reports',
          '',
          'CRAZY-COVERAGE					*crazy-coverage*',
          '',
          'Upstream documents this plugin in Markdown instead of vimdoc. Start at',
          'doc/index.md under: >',
          '	' .. plugin.dir,
          '<',
          ' vim:tw=78:ts=8:ft=help:norl:',
        }, help)
      end
      vim.cmd.helptags(doc)
    end,
    cmd = {
      'CoverageToggle',
      'CoverageLoad',
      'CoverageSummary',
      'CoverageNextUncovered',
      'CoveragePrevUncovered',
    },
    keys = {
      { '<leader>tc', '<cmd>CoverageToggle<cr>', desc = 'Toggle Coverage' },
      { '<leader>tC', '<cmd>CoverageSummary<cr>', desc = 'Coverage Summary' },
      { ']u', '<cmd>CoverageNextUncovered<cr>', desc = 'Next Uncovered Line' },
      { '[u', '<cmd>CoveragePrevUncovered<cr>', desc = 'Prev Uncovered Line' },
    },
    opts = {
      -- Root is excluded on purpose: the plugin falls back to scanning every
      -- file of a search dir, and treats any stray JSON/XML there as a report.
      coverage_dirs = {
        'coverage/bats', -- kcov output of scripts/test.sh --coverage
        'target/tarpaulin',
        'target/coverage',
        'build/coverage',
        'coverage',
        'build',
      },
      coverage_patterns = {
        shell = { 'cobertura.xml', 'coverage.xml', '*.lcov', '*.info' },
        c = {
          '*.lcov',
          '*.info',
          'coverage.json',
          'coverage.xml',
          '*.profdata',
        },
        cpp = {
          '*.lcov',
          '*.info',
          'coverage.json',
          'coverage.xml',
          '*.profdata',
        },
        python = {
          '.coverage',
          'coverage.json',
          'coverage.xml',
          'coverage.lcov',
        },
        rust = {
          '*.lcov',
          '*.info',
          'coverage.json',
          'coverage.xml',
          'coverage-tarpaulin.lcov',
          'coverage-tarpaulin.json',
          'coverage-tarpaulin.xml',
        },
        go = {
          'coverage.out',
          '*.lcov',
          '*.info',
          'coverage.json',
          'coverage.xml',
        },
      },
    },
  },
}
