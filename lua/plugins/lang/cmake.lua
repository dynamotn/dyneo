---@diagnostic disable-next-line: unused-local
local language = require('config.languages').cmake

return vim.list_contains(DyNeo.enabled_languages, 'cmake')
    and {
      {
        -- LSP config
        'neovim/nvim-lspconfig',
        opts = {
          servers = {
            neocmake = {},
            harper_ls = {},
          },
        },
      },
      {
        -- Powerful toolbox for CMake
        'Civitasv/cmake-tools.nvim',
        -- stylua: ignore
        keys = {
          { '<localleader>b', '<cmd>CMakeBuild<cr>', desc = 'CMake Build', ft = { 'cmake', 'c', 'cpp' } },
          { '<localleader>r', '<cmd>CMakeRun<cr>', desc = 'CMake Run', ft = { 'cmake', 'c', 'cpp' } },
          { '<localleader>g', '<cmd>CMakeGenerate<cr>', desc = 'CMake Generate', ft = { 'cmake', 'c', 'cpp' } },
          { '<localleader>t', '<cmd>CMakeSelectBuildType<cr>', desc = 'CMake Build Type', ft = { 'cmake', 'c', 'cpp' } },
        },
        -- Loaded for a buffer inside a CMake project, wherever Neovim was
        -- started from
        init = function()
          local group =
            vim.api.nvim_create_augroup('dyneo_cmake', { clear = true })
          vim.api.nvim_create_autocmd('FileType', {
            group = group,
            pattern = { 'cmake', 'c', 'cpp' },
            callback = function(args)
              if not vim.fs.root(args.buf, 'CMakeLists.txt') then return end
              vim.api.nvim_del_augroup_by_id(group)
              require('lazy').load({ plugins = { 'cmake-tools.nvim' } })
            end,
          })
        end,
        opts = {},
      },
    }
  or {}
