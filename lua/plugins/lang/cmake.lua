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
        init = function()
          local loaded = false
          local function check()
            local cwd = vim.uv.cwd()
            if vim.fn.filereadable(cwd .. '/CMakeLists.txt') == 1 then
              require('lazy').load({ plugins = { 'cmake-tools.nvim' } })
              loaded = true
            end
          end
          check()
          vim.api.nvim_create_autocmd('DirChanged', {
            group = vim.api.nvim_create_augroup(
              'dyneo_cmake',
              { clear = true }
            ),
            callback = function()
              if not loaded then check() end
            end,
          })
        end,
        opts = {},
      },
    }
  or {}
